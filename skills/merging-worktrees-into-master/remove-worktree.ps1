<#
.SYNOPSIS
  Retire one merged worktree: remove it, prune, prove the branch merged with `git cherry`, delete
  the branch, and purge MAX_PATH leftovers. Run only after the human said yes at Gate 4.

.DESCRIPTION
  Refuses (and changes nothing) when:
    - the branch is not checked out in any registered worktree and no -LeftoverPath was given
    - the worktree is dirty
    - `git cherry <base> <branch>` prints any '+' line (patch not proven on base)
    - the worktree path is not under <repo>\.claude\worktrees\
    - the live worktree probe returns fewer than 2 entries
  Never uses --force on `git worktree remove`. `git branch -D` is used (not -d) because in a
  git-svn repo the fast-forwarded SHAs are rewritten by dcommit; the cherry proof is what makes
  -D safe. The tip SHA is printed first so the branch can be recreated.

.PARAMETER Repo          Main checkout root, e.g. X:\dev\cafdexgo-web
.PARAMETER Branch        Branch exactly as `git worktree list --porcelain` shows it (without refs/heads/)
.PARAMETER Base          Integration branch. Default master.
.PARAMETER LeftoverPath  Only when `git worktree remove` already de-registered the worktree earlier
                         (MAX_PATH) and files remain: the directory to purge.

.EXAMPLE
  pwsh -NoProfile -File remove-worktree.ps1 -Repo X:\dev\cafdexgo-web -Branch claude/team-insights-redesign-724bb2
  pwsh -NoProfile -File remove-worktree.ps1 -Repo X:\dev\cafdexgo-web -Branch claude/foo-123456 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Branch,
    [string]$Base = 'master',
    [string]$LeftoverPath
)

$ErrorActionPreference = 'Continue'
$PSNativeCommandUseErrorActionPreference = $false

function Fail([string]$Msg) {
    Write-Output "REFUSED: $Msg"
    Write-Output "Nothing was changed."
    $global:LASTEXITCODE = 0
    exit 0
}

function Invoke-Git([string[]]$GitArgs) {
    # git.exe explicitly: a function named 'git' would shadow the executable (PowerShell is case-insensitive).
    $raw = @(& git.exe -C $Repo @GitArgs 2>&1)
    $lines = @($raw | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ Code = $LASTEXITCODE; Lines = $lines }
}

function Get-Worktrees {
    $r = Invoke-Git @('worktree', 'list', '--porcelain')
    if ($r.Code -ne 0) { Fail "git worktree list failed: $($r.Lines -join ' ')" }
    $blocks = @(); $cur = $null
    foreach ($l in $r.Lines) {
        if ($l -match '^worktree (.+)$') { if ($cur) { $blocks += [pscustomobject]$cur }; $cur = [ordered]@{ Path = $Matches[1]; Branch = $null; Prunable = $false } }
        elseif ($null -eq $cur) { continue }
        elseif ($l -match '^branch refs/heads/(.+)$') { $cur.Branch = $Matches[1] }
        elseif ($l -match '^prunable') { $cur.Prunable = $true }
    }
    if ($cur) { $blocks += [pscustomobject]$cur }
    return ,$blocks
}

# ---- sanity ------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { Fail "$Repo is not a git checkout" }
if ($Branch -eq $Base) { Fail "refusing to operate on the base branch '$Base'" }
$repoFull = (Resolve-Path -LiteralPath $Repo).Path.TrimEnd('\', '/')
$wtRoot = Join-Path $repoFull '.claude\worktrees'

$headBranch = (Invoke-Git @('symbolic-ref', '--short', '-q', 'HEAD')).Lines -join ''
if ($headBranch -eq $Branch) { Fail "the main checkout has '$Branch' checked out" }

$exists = Invoke-Git @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")
if ($exists.Code -ne 0) { Fail "branch '$Branch' does not exist" }
$tip = ($exists.Lines | Select-Object -First 1)

# ---- locate the worktree from a FRESH probe (directory names are not branch names) --------
$wts = Get-Worktrees
if ($wts.Count -lt 2) { Fail "live worktree probe returned $($wts.Count) entries — refusing to act on a suspicious list" }
$mine = @($wts | Where-Object { $_.Branch -eq $Branch })
$wtPath = $null
if ($mine.Count -gt 1) { Fail "'$Branch' is checked out in $($mine.Count) worktrees" }
elseif ($mine.Count -eq 1) { $wtPath = $mine[0].Path -replace '/', '\' }
elseif ($LeftoverPath) { $wtPath = (Resolve-Path -LiteralPath $LeftoverPath -ErrorAction SilentlyContinue).Path; if (-not $wtPath) { Fail "-LeftoverPath '$LeftoverPath' does not exist" } }
else { Fail "'$Branch' is not checked out in any registered worktree (pass -LeftoverPath if an earlier remove de-registered it and files remain)" }

if (-not $wtPath.StartsWith($wtRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Fail "worktree path '$wtPath' is not under '$wtRoot' — this script only retires harness worktrees"
}
$registered = ($mine.Count -eq 1)

# ---- dirty check --------------------------------------------------------------------------
if ($registered -and -not $mine[0].Prunable -and (Test-Path -LiteralPath $wtPath)) {
    $st = @(& git.exe -C $wtPath status --porcelain -uall 2>&1 | Where-Object { $null -ne $_ })
    if ($LASTEXITCODE -ne 0) { Fail "git status failed in '$wtPath': $($st -join ' ')" }
    if ($st.Count -gt 0) { Fail "worktree '$wtPath' has $($st.Count) uncommitted change(s); a dirty worktree is never retired by this script" }
}

# ---- merge proof BEFORE touching anything -------------------------------------------------
$cherry = Invoke-Git @('cherry', $Base, $Branch)
if ($cherry.Code -ne 0) { Fail "git cherry failed: $($cherry.Lines -join ' ')" }
$plus = @($cherry.Lines | Where-Object { $_ -like '+*' })
Write-Output "cherry $Base $Branch : $($cherry.Lines.Count) line(s), $($plus.Count) with '+'  (empty output = already an ancestor)"
if ($plus.Count -gt 0) {
    Write-Output "Commits with no patch-identical twin on $Base :"
    $plus | ForEach-Object { Write-Output "  $_" }
    Write-Output "git diff $Base $Branch --stat :"
    (Invoke-Git @('diff', $Base, $Branch, '--stat')).Lines | ForEach-Object { Write-Output "  $_" }
    Write-Output "If the stat is empty this is a patch-id artifact (e.g. a Windows filename case flip) and the human may delete by hand:"
    Write-Output "  git -C $Repo branch -D $Branch     # recovery: git -C $Repo branch $Branch $tip"
    Fail "'$Branch' is not proven merged into $Base"
}

Write-Output "Branch tip (recovery handle): $tip   ->  git -C $Repo branch $Branch $tip"

# ---- remove the worktree (never --force) --------------------------------------------------
if ($registered) {
    if ($PSCmdlet.ShouldProcess($wtPath, "git worktree remove")) {
        $rm = Invoke-Git @('worktree', 'remove', $wtPath)
        if ($rm.Code -ne 0) {
            $still = @((Get-Worktrees) | Where-Object { ($_.Path -replace '/', '\') -ieq $wtPath })
            if ($still.Count -gt 0 -and -not $still[0].Prunable) {
                Write-Output ($rm.Lines -join "`n")
                Fail "git worktree remove refused and the worktree is still registered (untracked/modified files or lock). Not forcing."
            }
            Write-Output "git worktree remove exited $($rm.Code) but the worktree is de-registered (Windows MAX_PATH). Files remaining will be purged."
        }
    }
}

if ($PSCmdlet.ShouldProcess($Repo, "git worktree prune")) {
    $pr = Invoke-Git @('worktree', 'prune', '-v'); if ($pr.Lines.Count -gt 0) { $pr.Lines | ForEach-Object { Write-Output "prune: $_" } }
}

if ($WhatIfPreference) {
    Write-Output "What if: Performing the operation 'git branch -D' on target '$Branch' (tip $tip), then purging '$wtPath'."
    $global:LASTEXITCODE = 0
    exit 0
}

# ---- the branch must not be checked out anywhere after prune ------------------------------
$after = @((Get-Worktrees) | Where-Object { $_.Branch -eq $Branch })
if ($after.Count -gt 0) { Fail "'$Branch' is still checked out at $($after[0].Path) after prune" }

if ($PSCmdlet.ShouldProcess($Branch, "git branch -D")) {
    $del = Invoke-Git @('branch', '-D', $Branch)
    if ($del.Code -ne 0) { Fail "git branch -D failed: $($del.Lines -join ' ')" }
    Write-Output ($del.Lines -join "`n")
}

# ---- purge leftovers (robocopy empty-mirror beats MAX_PATH) -------------------------------
if (Test-Path -LiteralPath $wtPath) {
    $live = @((Get-Worktrees) | Where-Object { ($_.Path -replace '/', '\') -ieq $wtPath })
    if ($live.Count -gt 0) { Fail "'$wtPath' re-appeared in git worktree list; not purging" }
    if ($PSCmdlet.ShouldProcess($wtPath, "robocopy empty-mirror + Remove-Item")) {
        $empty = Join-Path $env:TEMP ("empty-mirror-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        & robocopy $empty $wtPath /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
        $rc = $LASTEXITCODE   # 0-7 = success (2 = extra files removed); >= 8 = failure
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        if ($rc -ge 8) { Write-Output "WARN: robocopy exit $rc while purging '$wtPath' — check by hand" }
        Remove-Item -LiteralPath $wtPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $wtPath) { Write-Output "WARN: '$wtPath' still exists after purge" } else { Write-Output "purged: $wtPath" }
    }
}

Write-Output "DONE: worktree retired and branch '$Branch' deleted (tip was $tip)."
$global:LASTEXITCODE = 0
exit 0
