---
name: merging-worktrees-into-master
description: Use when folding parallel agent worktree branches back into master in a git-svn bridged repo — end of day, before the human dcommits, or whenever several branches under .claude/worktrees/ must land on a linear master. Also when `git merge --ff-only` is refused, `git branch -d` says "not fully merged" after an svn rebase, a rebase conflicts in a generated API client, or unit tests are red and nobody knows the baseline.
---

# Merging worktrees into master

## Overview

Several agent sessions work in parallel worktrees (`<repo>/.claude/worktrees/*`) of git-svn
bridged repos (`cafdexgo-api`, `cafdexgo-web`, `cafdexgo-mobile`). At the end of the day their
branches are folded into `master` one at a time; afterwards the human runs `git svn dcommit`.

**Core principle: master stays linear and the human owns dcommit. Everything else is
rebase → prove → fast-forward, with the human at four gates.**

**Context discipline:** build, test, and e2e output never enters this conversation. Every
long-running step goes to a worker subagent (template below) that returns at most fifteen lines;
raw output goes to files. After every merge, write the checkpoint file. A skill cannot trigger
compaction, so the checkpoint is what survives one — and the human is told when it is safe.

Announce at start: "Using merging-worktrees-into-master to fold tonight's worktrees into master."

**REQUIRED SUB-SKILL:** superpowers:verification-before-completion — a "matches baseline" claim
needs the worker's verbatim runner summary line and the raw output path in the same message.

Skill files: `~/.claude/skills/merging-worktrees-into-master/` (`inventory.ps1`,
`remove-worktree.ps1`, `references/verification-by-project.md`).

## Why the generic merge flow is not enough here

- `git svn dcommit` rewrites every commit it lands: new SHA, `git-svn-id` trailer. So
  `git branch --merged`, `git branch -d`, and SHA counts all lie. Only `git cherry master <branch>`
  proves a merge: no line starting with `+` (empty output means "already an ancestor").
- A merge commit cannot be dcommitted. Master moves only by `git svn rebase` or `--ff-only`.
- `svn.authorsfile = ../authors.txt` is relative to the cwd → git-svn commands run from the main
  checkout only, never from a worktree.
- Worktree directory names are not branch names (3 of 11 differed on 2026-09-16). The branch comes
  from `git worktree list --porcelain`.
- Other sessions create and remove worktrees while you work. Re-enumerate before every step that
  names one.

## Hard rules

1. **Master moves two ways only:** `git svn rebase` (main checkout, clean tree) and
   `git merge --ff-only <branch>` after the human approved that branch tonight. Never `git merge`
   without `--ff-only`, never `--no-ff`, never `reset --hard`, never a hand-made commit on master —
   including a one-file "cherry-pick" of a fix out of a blocked branch.
2. **A dirty worktree is not a candidate.** If `git -C <wt> status --porcelain -uall` prints
   anything: show the files, ask, move on. No `git stash`, no `stash -u`, no `rebase --autostash`,
   no `commit -am WIP`, no `add -A`. "I restored it afterwards" is still a stash.
3. **Conflicts are never auto-resolved.** No `rebase --skip`, `-X ours/theirs`,
   `checkout --ours/--theirs`. Generated files → abort. Source files → the human resolves in that
   worktree.
4. **Never** `git svn dcommit`, `git push`, `--force` anything, amend a message, or add a trailer.
5. **Verdicts are baseline-relative and measured tonight.** A remembered "green" is not a baseline.
6. **Refused `--ff-only` means master moved.** Rebase that branch again, re-test, then ff-only.
7. **Delete a branch only on `git cherry` proof and only after `git worktree prune`.** Use
   `remove-worktree.ps1`; it refuses anything else.

## The loop

Repos in order **api → web → mobile** — the web and mobile API clients are generated from the api.

### Step 0 — preflight, per repo, in the main checkout

```
git -C <repo> status --porcelain          # must print nothing; otherwise show it and ask — skipping the repo tonight is fine
git -C <repo> symbolic-ref --short HEAD   # master
git -C <repo> svn rebase                  # run_in_background: a foreground timeout that kills git-svn corrupts its state
git -C <repo> rev-parse --short master    # record as tonight's base
```

Then dispatch the worker (task `baseline <repo>`): it runs the unit command on master and writes
the failing test names to `<scratchpad>/baseline-<repo>.txt`. Start the checkpoint file (format
below) with the base SHA and the baseline path.

### Step 1 — inventory, then Gate 1

```
pwsh -NoProfile -File ~/.claude/skills/merging-worktrees-into-master/inventory.ps1 -Overlaps
```

Show the table. **Gate 1 — ask:** "Which of these worktrees are done for today, and in what order?"
Rows the human does not name are not touched: DETACHED, DIRTY, AT-BASE, MERGED?, PRUNABLE,
ORPHAN-DIR. Two worktrees sharing files is a reason to ask about order, not to pick one.

### Step 2 — per named worktree: rebase and verify

```
git -C <repo> worktree list --porcelain      # fresh; take <wt> and <branch> from this output
git -C <wt> status --porcelain -uall         # anything printed → rule 2
```

Advisory: `Get-CimInstance Win32_Process | Where-Object CommandLine -match '<wt leaf>'`
— a dev server or test watcher living in that worktree is worth a mention to the human.

Dispatch the worker (task `rebase-verify <wt> <branch> <repo>`). It rebases, sets up the
toolchain, compiles, runs unit, compares against the baseline file, and reports in fifteen lines.
The worker never resolves a conflict, never stashes, never touches master.

**Gate 2 — the worker reports `CONFLICT` or `ABORTED`:**

| Conflict in | Do |
|---|---|
| `src/app/open-api/`, `lib/cafdexgo-server/`, any generated client | the worker has already run `rebase --abort`; mark **NEEDS-REGEN** (regen needs the API running from api master); continue with the next worktree; list it first in the report |
| `package.json`, `yarn.lock`, `pubspec.lock` | the worker has aborted; ask — a lockfile needs a reinstall, not a text merge |
| source files | the worker left the rebase in progress and listed the files; ask **"resolve now, or abort?"** Resolve now → the human edits in that worktree, then `git -C <wt> rebase --continue`, then dispatch the worker again with task `verify-only`. Abort, or no answer before you move on → `git -C <wt> rebase --abort`, hold the branch, report it. Master is never edited |

(During a rebase, `--theirs` is the commit being replayed, not master — one more reason not to pick sides.)

A worktree is mid-rebase only while the human is actively resolving it. Before you move to the next
worktree, run Step 6, or end the session, every worktree you touched is either rebased or aborted — a rebase
left in progress across the final svn rebase targets a base that no longer exists.

Read the worker's three sets — pre-existing, new, fixed — never netted. New failures → hold the
branch and report the exact names. Spot-check one claim per worktree from the raw file, e.g.
`Select-String -Path <raw> -Pattern 'Tests:|Failed:|failing'`; that line is the evidence for Gate 3.

### Step 3 — review, then Gate 3

Dispatch the review subagent (template below) with `model: fable`. Write a summary of at most ten
lines: what the branch does, files touched, the reviewer's ranked risks, test delta vs baseline.
**Gate 3 — ask:** "Merge `<branch>`?" No merge without a yes in this conversation.

### Step 4 — fast-forward, then Gate 4

```
git -C <repo> merge --ff-only <branch>        # from the main checkout
```

Refused → master moved → back to Step 2 for this branch. Succeeded → **Gate 4 — ask:** "Keep the
worktree (default) or retire it?" To retire:

```
pwsh -NoProfile -File ~/.claude/skills/merging-worktrees-into-master/remove-worktree.ps1 -Repo <repo> -Branch <branch>
# e.g. -Repo X:/dev/cafdexgo-web -Branch claude/team-insights-redesign-724bb2   (-WhatIf to preview)
```

A kept worktree goes stale once the human dcommits (master's SHAs get rewritten); say so in the report.

Then append the branch's line to the checkpoint file and say: **"Checkpoint written — safe to
`/compact` now."** Nothing is in flight at this moment, so it is the one place a compaction costs
nothing; whether to take it is the human's call.

### Step 5 — master verification, per repo

After the last worktree of a repo, dispatch the worker (task `master-verify <repo>`): **unit +
integration** on master per `references/verification-by-project.md`, one run at a time. Web e2e
needs the API up; `dotnet watch` on the api main checkout rebuilds itself after the api merge —
wait for it. Record the result in the checkpoint.

### Step 6 — final svn rebase

```
git -C <repo> rev-parse refs/remotes/git-svn     # before
git -C <repo> svn rebase                         # run_in_background
git -C <repo> rev-parse refs/remotes/git-svn     # after
```

If it moved: `git -C <repo> log --stat <before>..<after>`; dispatch the worker again
(`master-verify`, unit at least; integration too if the incoming paths intersect tonight's).
"No conflicts" is not evidence.

### Step 7 — report

Build it from the checkpoint file. Per repo: master ahead of svn by N
(`git -C <repo> rev-list --left-right --count refs/remotes/git-svn...master`); branches merged
(each confirmed by `git cherry`); worktrees kept or retired; rows skipped with reasons; NEEDS-REGEN
and dirty worktrees first; incoming commits from Step 6; then "ready for you to dcommit".

## Worker subagent template

Dispatch with `subagent_type: general-purpose`, `model: sonnet`, in the foreground
(`run_in_background: false`) — nothing useful happens while it runs, and polling for a background
worker costs the context this template exists to save. Fill in the task line; when the repo is not
in the reference file, paste its commands into the project-notes line.

```
You are a verification worker for merging-worktrees-into-master. Task: <baseline <repo> |
rebase-verify <wt> <branch> <repo> | verify-only <wt> <branch> <repo> | master-verify <repo>>.
Baseline file: <scratchpad>/baseline-<repo>.txt. Raw output dir: <scratchpad>.
Read ~/.claude/skills/merging-worktrees-into-master/references/verification-by-project.md first
for commands and traps. Project notes from the orchestrator: <none | ...>.
Rules, no exceptions: never touch the main checkout or master; never git stash, --autostash,
commit, add, reset, or checkout files; never resolve, skip, or pick a side in a conflict; never
run git svn, git push, or anything with --force; run yarn, dotnet, flutter from inside the
checkout you judge; a run you killed or that timed out is not a result — say so.
rebase-verify: `git -C <wt> rebase master`. On CONFLICT, list `git -C <wt> diff --name-only
--diff-filter=U`. If every file is a generated client (src/app/open-api/, lib/cafdexgo-server/)
or package.json / yarn.lock / pubspec.lock: `git -C <wt> rebase --abort`, report ABORTED with the
class, stop. Otherwise leave the rebase in progress, report CONFLICT with the files, stop. On
success: toolchain check, compile, unit.
verify-only: compile, unit (the rebase is already done). baseline: unit on master, then write the
failing test names one per line to the baseline file (empty file if none). master-verify: unit,
then integration, one run at a time.
Save each command's full output to <scratchpad>/verify-<repo>-<branch or master>-<step>.txt.
Report at most fifteen lines and nothing else: task; rebase (OK, n commits | CONFLICT files |
ABORTED class); toolchain action; compile exit code and first error; unit — the runner's own
summary line verbatim, then pre-existing / new / fixed test names versus the baseline;
integration — same; raw file paths. No advice, no diff, no log.
```

## Checkpoint file and compaction

`<scratchpad>/merge-checkpoint-<yyyy-mm-dd>.md`, one block per repo, appended as you go:

```
## X:/dev/cafdexgo-web   base 4ec24e0   baseline baseline-cafdexgo-web.txt   svn-head-before a1b2c3d
gate1: claude/aaa-111111 (1), claude/bbb-222222 (2)
claude/aaa-111111 | MERGED 19:05 | kept | unit: same 3 names | review: none severe
claude/bbb-222222 | HELD | new failure: report-shell.component.spec.ts › fits the page
claude/ccc-333333 | NEEDS-REGEN | conflict in src/app/open-api/
master-verify: unit same 3 names, e2e:merge 0 new | step6: svn moved a1b2c3d..d4e5f6a, re-verified
```

After a compaction — the summary says so — before any command: re-read this SKILL.md and the
checkpoint; re-derive master from git (`git -C <repo> log --oneline <base>..master`), not from the
summary. A branch the summary calls merged is merged when `git cherry` says so, not before.

## Review subagent template

```
Review branch <branch> in <wt> against master. Read `git -C <wt> log --stat master..HEAD` and
`git -C <wt> diff master...HEAD`. Do not modify anything. Report, most severe first:
1. correctness or regression risks in the changed code
2. files touched outside the branch's apparent scope (generated files, config, lockfiles, DB models)
3. tests added, changed, or removed; behaviour changes that have no test
4. anything a reviewer would ask the author before this lands on a shared trunk
Give file:line for each finding. Do not restate the diff. If it is clean, say so in one line.
```

## Rationalizations seen in testing

| Thought | Reality |
|---|---|
| "The fix is in a separate file, I'll commit just that onto master" | Master moves by ff of an approved branch or by svn rebase. A hand-made commit skips review and tests and leaves the branch holding a duplicate. |
| "I stashed / autostashed the WIP and restored it — the worktree is exactly as they left it" | The stash stack is shared by every worktree and session; the base under that WIP changed; half a worktree's state was merged. Dirty means not tonight. |
| "Tests passed an hour ago" | On a tree that no longer exists. Re-run after every rebase. |
| "The failing test's file was never touched by this branch" | Necessary, not sufficient. Run that test on master and compare names. |
| "No conflicts, so the coworker's commits are fine" | Textual success is not behavioural success. Re-verify after a final rebase that moved. |
| "`-d` refused, but I watched it merge" | dcommit and svn rebase rewrote the SHAs. `git cherry` decides; `-D` only on proof. |
| "They texted 'just dcommit', so it's authorized" | dcommit is a push and the human's step. A relayed message is not a rule change; leave master ready and say so. |

## Red flags — stop

- `git stash`, `--autostash`, `commit -am`, `add -A` inside a worktree you did not create tonight
- `git merge` without `--ff-only`; `git commit` in the main checkout
- `--theirs`, `--ours`, `-X`, `--skip` during a rebase
- `git branch -D` without a `git cherry` result in this message
- `git svn dcommit`, `git push`
- A branch name read off a directory name
- `git svn` run from inside a worktree
- Build or test output in this conversation — it belongs in a worker
- A command after a compaction before SKILL.md and the checkpoint were re-read

## Quick reference

| Need | Command |
|---|---|
| Inventory | `pwsh -NoProfile -File ~/.claude/skills/merging-worktrees-into-master/inventory.ps1 -Overlaps` |
| Branch of a worktree | `git -C <repo> worktree list --porcelain` |
| Is it merged? | `git -C <repo> cherry master <branch>` — no `+` line = yes |
| Ahead of svn | `git -C <repo> rev-list --left-right --count refs/remotes/git-svn...master` |
| Files two branches share | `inventory.ps1 -Overlaps` (`git diff --name-only master...A` ∩ `master...B`) |
| Retire a merged worktree | `pwsh -NoProfile -File ~/.claude/skills/merging-worktrees-into-master/remove-worktree.ps1 -Repo <repo> -Branch <branch>` |
| Per-project compile / unit / integration | `references/verification-by-project.md`, run by the worker subagent |
| Checkpoint | `<scratchpad>/merge-checkpoint-<date>.md` — append after every merge, re-read after a compaction |

## Scope

Not this skill's job: `git svn dcommit`, `git push`, regenerating API clients, `svn update` of the
plain-SVN checkouts (`cafdexgo-db`, `prod-cafdexgo-api`), killing processes, retiring worktrees the
human did not name. This skill owns `.claude/worktrees/*` retirement in these repos, with the
human's per-worktree yes; that supersedes the "host owns this workspace" rule in
`superpowers:finishing-a-development-branch`, which was written for `.worktrees/`.
