<#
.SYNOPSIS
  Read-only inventory of git worktrees for the end-of-day merge sweep.

.DESCRIPTION
  For each repo: one MAIN row (main checkout vs refs/remotes/git-svn and vs the git remote),
  then one row per registered worktree with the branch read from `git worktree list --porcelain`
  (never from the directory name), patch-id merge evidence from `git cherry`, dirty count,
  and toolchain presence. Orphan directories under .claude/worktrees and branches without a
  worktree are listed separately.

  Never writes: no fetch, no svn, no prune, no cd. Every git call uses -C.
  Always exits 0; per-item failures print as '?' cells plus a WARN line.

.PARAMETER Repos
  Repo roots, in processing order. Default: api, web, mobile.
.PARAMETER Base
  Integration branch. Default: master.
.PARAMETER Overlaps
  Also print, per repo, pairs of ahead worktrees that touch the same files.
.PARAMETER Json
  Emit the rows as JSON instead of tables.

.EXAMPLE
  pwsh -NoProfile -File inventory.ps1
  pwsh -NoProfile -File inventory.ps1 -Overlaps
  pwsh -NoProfile -File inventory.ps1 -Json | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [string[]]$Repos = @('X:\dev\cafdexgo-api', 'X:\dev\cafdexgo-web', 'X:\dev\cafdexgo-mobile'),
    [string]$Base = 'master',
    [switch]$Overlaps,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

$script:Warnings = New-Object System.Collections.Generic.List[string]

function Invoke-Git {
    param([string]$Dir, [string[]]$GitArgs)
    $raw = @(& git -C $Dir @GitArgs 2>&1)
    $code = $LASTEXITCODE
    $out = [System.Collections.Generic.List[string]]::new()
    $err = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $raw) {
        if ($null -eq $line) { continue }
        if ($line -is [System.Management.Automation.ErrorRecord]) { $err.Add($line.ToString()) }
        else { $out.Add([string]$line) }
    }
    [pscustomobject]@{ Code = $code; Out = $out.ToArray(); Err = $err.ToArray() }
}

function Git-Text {
    # Returns the first output line, or $null (and records a WARN) on failure.
    param([string]$Dir, [string[]]$GitArgs, [string]$What)
    $r = Invoke-Git -Dir $Dir -GitArgs $GitArgs
    if ($r.Code -ne 0) {
        $first = if ($r.Err.Count -gt 0) { $r.Err[0] } elseif ($r.Out.Count -gt 0) { $r.Out[0] } else { "exit $($r.Code)" }
        $script:Warnings.Add("$What`: $first")
        return $null
    }
    if ($r.Out.Count -eq 0) { return '' }
    return $r.Out[0]
}

function Git-Lines {
    param([string]$Dir, [string[]]$GitArgs, [string]$What)
    $r = Invoke-Git -Dir $Dir -GitArgs $GitArgs
    if ($r.Code -ne 0) {
        $first = if ($r.Err.Count -gt 0) { $r.Err[0] } elseif ($r.Out.Count -gt 0) { $r.Out[0] } else { "exit $($r.Code)" }
        $script:Warnings.Add("$What`: $first")
        return $null
    }
    # Leading comma keeps an empty or single-line result an array; a bare return would unroll it.
    return ,[string[]]$r.Out
}

function Get-LeftRight {
    # "behind ahead" of $Right relative to $Left, as two ints, or $null.
    param([string]$Dir, [string]$Left, [string]$Right, [string]$What)
    $t = Git-Text -Dir $Dir -GitArgs @('rev-list', '--left-right', '--count', "$Left...$Right") -What $What
    if ($null -eq $t) { return $null }
    $parts = $t -split '\s+' | Where-Object { $_ -ne '' }
    if ($parts.Count -lt 2) { return $null }
    return @([int]$parts[0], [int]$parts[1])
}

function Get-RepoKind {
    param([string]$Root)
    if (Test-Path -LiteralPath (Join-Path $Root 'angular.json')) { return 'web' }
    if (Test-Path -LiteralPath (Join-Path $Root 'pubspec.yaml')) { return 'mobile' }
    if (Get-ChildItem -LiteralPath $Root -Filter '*.sln' -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return 'api' }
    if (Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Select-Object -First 1) { return 'api' }
    return 'unknown'
}

function Get-Toolchain {
    param([string]$Kind, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'missing-dir' }
    switch ($Kind) {
        'web' {
            $nm = Test-Path -LiteralPath (Join-Path $Path 'node_modules\.bin\jest.cmd')
            $cert = (Test-Path -LiteralPath (Join-Path $Path 'certificate\localhost.pem')) -and
                    (Test-Path -LiteralPath (Join-Path $Path 'certificate\localhost-key.pem'))
            return "nm:$(if ($nm) {'Y'} else {'N'}) cert:$(if ($cert) {'Y'} else {'N'})"
        }
        'mobile' {
            $dt = Test-Path -LiteralPath (Join-Path $Path '.dart_tool\package_config.json')
            return "dart_tool:$(if ($dt) {'Y'} else {'N'})"
        }
        default { return '-' }
    }
}

function Parse-WorktreeList {
    param([string]$Root)
    $lines = Git-Lines -Dir $Root -GitArgs @('worktree', 'list', '--porcelain') -What "$Root worktree list"
    if ($null -eq $lines) { return $null }
    $blocks = @(); $cur = $null
    foreach ($l in $lines) {
        if ($l -match '^worktree (.+)$') {
            if ($cur) { $blocks += $cur }
            $cur = [ordered]@{ Path = $Matches[1]; Head = $null; Branch = $null; Detached = $false; Prunable = $false; Locked = $false }
        }
        elseif ($null -eq $cur) { continue }
        elseif ($l -match '^HEAD (\w+)$') { $cur.Head = $Matches[1] }
        elseif ($l -match '^branch refs/heads/(.+)$') { $cur.Branch = $Matches[1] }
        elseif ($l -match '^detached') { $cur.Detached = $true }
        elseif ($l -match '^prunable') { $cur.Prunable = $true }
        elseif ($l -match '^locked') { $cur.Locked = $true }
    }
    if ($cur) { $blocks += $cur }
    return $blocks | ForEach-Object { [pscustomobject]$_ }
}

$allMain = @(); $allWt = @(); $allExtra = @(); $allOverlaps = @()

foreach ($repo in $Repos) {
    $repoName = Split-Path -Leaf $repo
    if (-not (Test-Path -LiteralPath $repo)) {
        $allMain += [pscustomobject]@{ Repo = $repoName; Branch = 'MISSING'; Dirty = '?'; SvnAhead = '?'; SvnBehind = '?'; Remote = '?'; RemoteAhead = '?'; RemoteBehind = '?'; SvnHeadAge = '?' }
        continue
    }
    $kind = Get-RepoKind -Root $repo

    # ---- MAIN row -------------------------------------------------------------------------
    $branch = Git-Text -Dir $repo -GitArgs @('symbolic-ref', '--short', '-q', 'HEAD') -What "$repoName symbolic-ref"
    if ([string]::IsNullOrEmpty($branch)) { $branch = 'DETACHED' }
    $dirtyLines = Git-Lines -Dir $repo -GitArgs @('status', '--porcelain', '-uall') -What "$repoName status"
    $dirty = if ($null -eq $dirtyLines) { '?' } else { $dirtyLines.Count }

    $svn = Get-LeftRight -Dir $repo -Left 'refs/remotes/git-svn' -Right $Base -What "$repoName svn rev-list"
    $svnBehind = if ($svn) { $svn[0] } else { 'n/a' }
    $svnAhead = if ($svn) { $svn[1] } else { 'n/a' }
    $svnAge = Git-Text -Dir $repo -GitArgs @('log', '-1', '--format=%cr', 'refs/remotes/git-svn') -What "$repoName svn head age"
    if ($null -eq $svnAge) { $svnAge = 'n/a' }

    $remoteLines = Git-Lines -Dir $repo -GitArgs @('remote') -What "$repoName remote"
    $remote = if ($null -ne $remoteLines -and @($remoteLines).Count -gt 0) { @($remoteLines)[0] } else { 'none' }
    $rem = if ($remote -ne 'none') { Get-LeftRight -Dir $repo -Left "$remote/$Base" -Right $Base -What "$repoName remote rev-list" } else { $null }
    $remBehind = if ($rem) { $rem[0] } else { 'n/a' }
    $remAhead = if ($rem) { $rem[1] } else { 'n/a' }

    $allMain += [pscustomobject]@{
        Repo = $repoName; Branch = $branch; Dirty = $dirty
        SvnAhead = $svnAhead; SvnBehind = $svnBehind
        Remote = $remote; RemoteAhead = $remAhead; RemoteBehind = $remBehind
        SvnHeadAge = $svnAge
    }

    # ---- worktree rows --------------------------------------------------------------------
    $blocks = Parse-WorktreeList -Root $repo
    if ($null -eq $blocks) { continue }
    $registered = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $wtBranches = New-Object System.Collections.Generic.HashSet[string]
    $aheadRows = @()

    foreach ($b in ($blocks | Select-Object -Skip 1)) {
        $leaf = Split-Path -Leaf $b.Path
        [void]$registered.Add($leaf)
        try {
            $ref = if ($b.Branch) { $b.Branch } else { $b.Head }
            if ($b.Branch) { [void]$wtBranches.Add($b.Branch) }
            $branchCell = if ($b.Branch) { $b.Branch } else { 'DETACHED' }
            if ($b.Prunable) { $branchCell += ' PRUNABLE' }
            if ($b.Locked) { $branchCell += ' LOCKED' }

            $cherry = Git-Lines -Dir $repo -GitArgs @('cherry', $Base, $ref) -What "$repoName cherry $leaf"
            $plus = if ($null -eq $cherry) { '?' } else { @($cherry | Where-Object { $_ -like '+*' }).Count }
            $minus = if ($null -eq $cherry) { '?' } else { @($cherry | Where-Object { $_ -like '-*' }).Count }

            $aheadSha = Git-Text -Dir $repo -GitArgs @('rev-list', '--count', "$Base..$ref") -What "$repoName ahead $leaf"
            if ($null -eq $aheadSha) { $aheadSha = '?' } else { $aheadSha = [int]$aheadSha }
            $behind = Git-Text -Dir $repo -GitArgs @('rev-list', '--count', "$ref..$Base") -What "$repoName behind $leaf"
            if ($null -eq $behind) { $behind = '?' } else { $behind = [int]$behind }

            if ($b.Prunable -or -not (Test-Path -LiteralPath $b.Path)) { $wtDirty = '?' }
            else {
                $dl = Git-Lines -Dir $b.Path -GitArgs @('status', '--porcelain', '-uall') -What "$repoName status $leaf"
                $wtDirty = if ($null -eq $dl) { '?' } else { $dl.Count }
            }

            $age = Git-Text -Dir $repo -GitArgs @('log', '-1', '--format=%cr', $b.Head) -What "$repoName age $leaf"
            if ($null -eq $age) { $age = '?' }

            $tool = Get-Toolchain -Kind $kind -Path $b.Path

            $hint =
                if ($b.Prunable) { 'PRUNABLE' }
                elseif (-not $b.Branch) { 'DETACHED' }
                elseif ($wtDirty -is [int] -and $wtDirty -gt 0) { "DIRTY($wtDirty)" }
                elseif ($plus -is [int] -and $plus -eq 0 -and $aheadSha -is [int] -and $aheadSha -eq 0) { 'AT-BASE' }
                elseif ($plus -is [int] -and $plus -eq 0) { 'MERGED?' }
                elseif ($behind -is [int] -and $behind -ge 50) { 'STALE?' }
                else { 'CANDIDATE' }

            $row = [pscustomobject]@{
                Repo = $repoName; Worktree = $leaf; Branch = $branchCell
                'Cherry+' = $plus; 'Cherry-' = $minus; AheadSha = $aheadSha; Behind = $behind
                Dirty = $wtDirty; Toolchain = $tool; LastCommit = $age; Hint = $hint; Path = $b.Path
            }
            $allWt += $row
            if ($b.Branch -and $plus -is [int] -and $plus -gt 0) { $aheadRows += $row }
        }
        catch {
            $script:Warnings.Add("$repoName $leaf`: $($_.Exception.Message)")
            $allWt += [pscustomobject]@{
                Repo = $repoName; Worktree = $leaf; Branch = '?'; 'Cherry+' = '?'; 'Cherry-' = '?'
                AheadSha = '?'; Behind = '?'; Dirty = '?'; Toolchain = '?'; LastCommit = '?'; Hint = 'ERROR'; Path = $b.Path
            }
        }
    }

    # ---- orphan directories + branches without a worktree ---------------------------------
    $wtRoot = Join-Path $repo '.claude\worktrees'
    if (Test-Path -LiteralPath $wtRoot) {
        foreach ($d in (Get-ChildItem -LiteralPath $wtRoot -Directory -ErrorAction SilentlyContinue)) {
            if (-not $registered.Contains($d.Name)) {
                $allExtra += [pscustomobject]@{ Repo = $repoName; Kind = 'ORPHAN-DIR'; Item = $d.Name; Note = 'on disk, not in `git worktree list` — never touched by the sweep; prune/purge is a human decision' }
            }
        }
    }
    $heads = Git-Lines -Dir $repo -GitArgs @('for-each-ref', '--format=%(refname:short)', 'refs/heads') -What "$repoName for-each-ref"
    if ($heads) {
        $noWt = @($heads | Where-Object { $_ -ne $Base -and -not $wtBranches.Contains($_) })
        if ($noWt.Count -gt 0) {
            $allExtra += [pscustomobject]@{ Repo = $repoName; Kind = 'BRANCH-NO-WORKTREE'; Item = "$($noWt.Count) branch(es)"; Note = ($noWt -join ', ') + ' — not sweep candidates' }
        }
    }

    # ---- pairwise file overlaps among ahead worktrees ------------------------------------
    if ($Overlaps -and $aheadRows.Count -ge 2) {
        $files = @{}
        foreach ($r in $aheadRows) {
            $br = ($r.Branch -split ' ')[0]
            $f = Git-Lines -Dir $repo -GitArgs @('diff', '--name-only', "$Base...$br") -What "$repoName diff names $($r.Worktree)"
            $files[$r.Worktree] = if ($null -eq $f) { @() } else { @($f) }
        }
        $names = @($files.Keys | Sort-Object)
        for ($i = 0; $i -lt $names.Count; $i++) {
            for ($j = $i + 1; $j -lt $names.Count; $j++) {
                $common = @($files[$names[$i]] | Where-Object { $files[$names[$j]] -contains $_ })
                if ($common.Count -gt 0) {
                    $allOverlaps += [pscustomobject]@{ Repo = $repoName; A = $names[$i]; B = $names[$j]; SharedFiles = $common.Count; Sample = (($common | Select-Object -First 3) -join ', ') }
                }
            }
        }
    }
}

if ($Json) {
    [pscustomobject]@{ Main = $allMain; Worktrees = $allWt; Extra = $allExtra; Overlaps = $allOverlaps; Warnings = @($script:Warnings) } |
        ConvertTo-Json -Depth 4
}
else {
    Write-Output "=== MAIN CHECKOUTS (base: $Base) ==="
    $allMain | Format-Table Repo, Branch, Dirty, SvnAhead, SvnBehind, Remote, RemoteAhead, RemoteBehind, SvnHeadAge -AutoSize | Out-String -Width 220 | Write-Output
    Write-Output "=== WORKTREES ==="
    $allWt | Format-Table Repo, Worktree, Branch, 'Cherry+', 'Cherry-', AheadSha, Behind, Dirty, Toolchain, LastCommit, Hint -AutoSize | Out-String -Width 260 | Write-Output
    if ($allExtra.Count -gt 0) {
        Write-Output "=== NOT CANDIDATES ==="
        $allExtra | Format-Table Repo, Kind, Item, Note -AutoSize -Wrap | Out-String -Width 220 | Write-Output
    }
    if ($Overlaps) {
        Write-Output "=== FILE OVERLAPS BETWEEN AHEAD WORKTREES ==="
        if ($allOverlaps.Count -eq 0) { Write-Output "(none)`n" }
        else { $allOverlaps | Format-Table Repo, A, B, SharedFiles, Sample -AutoSize -Wrap | Out-String -Width 220 | Write-Output }
    }
    Write-Output @"
Legend
  Cherry-  : commits whose patch already exists on $Base under another SHA. All-minus = PROOF the branch is merged.
  Cherry+  : commits with no byte-identical patch on $Base. NOT proof of unmerged work: a Windows filename case flip,
             a squashed or conflict-resolved landing, or a git-svn rewrite all break patch-id matching.
             Confirm with:  git diff $Base <branch> --stat   (empty => merged).
  AheadSha : plain SHA count ($Base..branch). Disagreement with Cherry+ is expected after dcommit rewrites.
  Hint     : DETACHED / PRUNABLE / DIRTY(n) / AT-BASE / MERGED? / STALE? (>=50 behind) / CANDIDATE. Advisory only —
             the human names the worktrees to process.
  SvnAhead : commits on $Base not yet in refs/remotes/git-svn (the human dcommits these). SvnBehind>0 => run git svn rebase.
"@
    if ($script:Warnings.Count -gt 0) {
        Write-Output "=== WARNINGS ==="
        foreach ($w in $script:Warnings) { Write-Output "WARN: $w" }
    }
}

# robocopy-style exit-code leaks are common here; make the read-only inventory unambiguous.
$global:LASTEXITCODE = 0
exit 0
