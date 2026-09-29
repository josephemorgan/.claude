# Claude Code personal config

The portable part of `~/.claude`, tracked as a git repo in place. `.gitignore` is an
allowlist; anything not listed there (credentials, `settings.local.json`, transcripts,
memory, plugin caches) is machine-local and never committed.

## New machine

1. `git clone <this repo> ~/.claude` before the first `claude` launch (or clone
   elsewhere and copy the tracked files in).
2. Log in with `claude` as usual; login is per machine and not part of this repo.
3. Reinstall plugins: `enabledPlugins` in `settings.json` lists them, but the
   installs themselves live in the untracked `plugins/` cache.
4. Fix machine-specific paths in `settings.json`: the `local-plugins` marketplace
   path and `permissions.additionalDirectories`.

## Layout

- `CLAUDE.md` global instructions
- `settings.json`, `keybindings.json`, `statusline-command.js`
- `skills/` personal skills (invoke with `/<name>`)
- `agents/` custom subagent types with pinned models
- `output-styles/` custom output styles
- `local-plugins/` directory marketplace for local plugins
