# Verification by project

Read this when the loop reaches "compile + unit" for a worktree, or "unit + integration" for master.
The worker subagent runs these commands; the orchestrator only reads its fifteen-line report.
Commands were checked against the repos on 2026-09-16. If one has moved, fix it here, not in SKILL.md.

## Rules for every project

- **Baseline first.** Before merging anything into a repo, run its unit command on master and save
  the failing test names to `<scratchpad>/baseline-<repo>.txt`. Every later verdict is "same
  names / new names / fixed names", never "green" or "red".
- **Run from inside the checkout you are judging.** `git -C` does not apply to yarn, dotnet, flutter.
- **Per worktree:** compile + unit. **Master, at the end:** unit + integration, once per repo,
  serialized (the web e2e suite cannot run twice at once).
- **Full output to a file, summary to the report.** Redirect or tee every run to
  `<scratchpad>/verify-<repo>-<branch or master>-<step>.txt`; the report carries the runner's own
  summary line verbatim plus the path. Runs longer than the Bash tool's ten-minute cap (web e2e is
  about eleven) go `run_in_background` and are read when the task notification arrives. A
  foreground timeout that kills a test run is not a failed test run.
- **Reading results:** list three sets — failing on baseline and now (pre-existing), failing now
  only (regression: hold the branch), failing on baseline only (fixed: mention it, still merge).
  Never net them. If the branch added or renamed tests, say so separately.

## cafdexgo-web — Angular 20, **yarn, never npm**

| Step | Command | Notes |
|---|---|---|
| compile | `yarn ng build --configuration development` | Direct `ng` skips the `prebuild` hook. `yarn build` bumps package.json's patch version every run; if package.json shows modified afterwards, `git checkout -- package.json`. Node 22 (`.nvmrc`). If it runs out of heap, prefix `NODE_OPTIONS=--max_old_space_size=12288`. |
| unit | `yarn test` | Jest, about 155 s for ~50 suites (2026-09-08). Baseline was green then but is branch-dependent; measure tonight. One file: `yarn jest <path>`. |
| integration, master only | `yarn e2e:merge` | Playwright with `E2E_FRESH_SERVER=1`: refuses to reuse a running dev server and starts `ng serve` on 4200 itself. Needs the API answering on `https://localhost:5001` (Morgan's `dotnet watch`), port 4200 free, `certificate/*.pem`, Playwright Chromium (`yarn e2e:install`, once per machine). `e2e/.env` (`E2E_LOGIN_EMAIL` / `E2E_LOGIN_PASSWORD`) is optional; without it the session tests skip themselves. About 11 min. **Never run two Playwright invocations at once** — each start clears `test-results/`. |
| lint | `yarn ng lint --lint-file-patterns=<file>` (scoped) | Repo-wide `yarn lint` fails on ~1977 baseline problems. Not a gate. |

Worktree toolchain:

- **No `node_modules`:** if `git diff master <branch> -- package.json yarn.lock` is empty, junction
  the main checkout's: `cmd /c mklink /J "<wt>\node_modules" "X:\dev\cafdexgo-web\node_modules"`
  (instant, ignored by git). Otherwise `yarn install --frozen-lockfile` (about 10 min).
- Without its own `node_modules`, Jest in a worktree resolves modules from the main checkout three
  directories up and the result is not trustworthy. Fix the toolchain before reading any result.
- `certificate/*.pem` matter only for `ng serve` and e2e, not for unit tests. Copy from the main
  checkout or run `yarn setup:certs`.
- A rebase under a running `ng serve` leaves a stale bundle: the watcher misses git-level file
  restores. Touch a changed file (`(Get-Item <file>).LastWriteTime = Get-Date`) before trusting it.
- `src/app/open-api/open-api.client.ts` is generated (`yarn nswag:build`, needs the API on :5000).
  Never resolve a conflict in it by hand or by picking a side.
- `.claude/worktrees/` is hidden from `git status` by `.git/info/exclude` (machine-local). On a new
  machine, add it there or the main checkout looks dirty.

## cafdexgo-api — .NET, SDK 10.0.302 (`global.json`)

| Step | Command | Notes |
|---|---|---|
| compile | `dotnet build CAFDExGOServer.sln` | Run in the worktree. Morgan's `dotnet watch` holds `bin/Debug` in the main checkout. |
| unit | `dotnet test test/CAFDExGOServer.Tests/CAFDExGOServer.Tests.csproj --artifacts-path <scratchpad>/api-artifacts-<worktree>` | `--artifacts-path` is mandatory: without it the build collides with `dotnet watch`'s locked `apphost.exe` (MSB3027/MSB3021). Baseline 2026-09: 431/436, 5 pre-existing failures. Compare names. |
| integration | none | The web e2e suite exercises the API. After the ff-merge into api master, `dotnet watch` rebuilds the main checkout on its own; wait for it before running web e2e. |

Notes: no CLAUDE.md inside this repo (only `X:\dev\CLAUDE.md`, partly stale). `appsettings*.json`
are tracked, so a fresh worktree is config-complete. Format with `dnx csharpier -y format <files>`
from PowerShell, not Git Bash. `Models/*.cs` and the two DB contexts are scaffolded from the
database: a branch that edits them needs its `RUN_ONCE` SQL — raise it in the review summary.

## cafdexgo-mobile — Flutter (SDK checkout at `X:\packages\flutter`)

| Step | Command | Notes |
|---|---|---|
| compile | `flutter analyze` | |
| unit | `flutter test` | Green baseline (2,954 tests, 2026-09-11). Any failure is a delta until master is measured. One file: `flutter test <path>`. |
| integration, master only | `flutter test integration_test/` | Needs a device or emulator; see the `run-cafdexgo-mobile` skill. On Morgan's machine the launch gate is waived by the global CLAUDE.md. |

Worktree toolchain: `.dart_tool/package_config.json` missing → `flutter pub get` in the worktree.

Traps: `lib/config/settings_dev.dart` is rewritten by a machine-local smudge filter — `git status`
says clean while the bytes differ from HEAD. By design; never "fix" or commit it. `android/.gradle`
is tracked and can block branch switches. `lib/cafdexgo-server/` is the generated Dart API client:
never resolve a conflict in it by hand or by picking a side.
