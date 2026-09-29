# dart-lsp

Dart language server for Claude Code, providing code intelligence and diagnostics
in Flutter/Dart projects (`cafdexgo-mobile`).

## Supported Extensions

`.dart`

## Why this is a local plugin

There is no `dart-lsp` in the official Claude Code marketplace (which ships clangd,
csharp, gopls, jdtls, kotlin, lua, php, pyright, ruby, rust-analyzer, swift, and
typescript). This plugin fills that gap using the analysis server that already ships
inside the Flutter SDK — nothing extra to install.

## Server binary

    X:\packages\flutter\bin\cache\dart-sdk\bin\dart.exe language-server --protocol=lsp

This points at the real `dart.exe` rather than `X:\packages\flutter\bin\dart.bat`
on purpose: `.bat` files cannot be spawned without a shell on Windows.

Because the Flutter SDK here is a git checkout, this path follows whatever version
the checkout is on — no separate Dart SDK to keep in sync.

## Notes

- First initialization in `cafdexgo-mobile` is slow; the analysis server persists its
  index under `~/.dartServer`, so the cost is paid once rather than per session.
- If the Flutter SDK moves off `X:\packages\flutter`, update `command` in
  `~/.claude/local-plugins/.claude-plugin/marketplace.json`.
