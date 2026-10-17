# Changelog

Notable changes to Slash Command. Versions follow [Semantic Versioning](https://semver.org).

## 0.2.0

- **Windows app.** A tray app for Windows 11 (x64): Shift+Alt+1 … 9 and Shift+Alt+= / - while Windows Terminal, Orca or WezTerm is in front, a notice that never takes focus, and a tray menu with the presets. Download `Slash-Command-Windows-x64.zip`.
- The command line tool runs on Windows too, with `--app windowsterminal`, `--console <pid>`, `--app orca` and `--wezterm <pane>` targets.
- On Windows, child processes start without a console window.

## 0.1.0

First public release.

- Hotkeys `⇧⌥1` … `⇧⌥9` switch the frontmost agent to a preset's model and effort. `⇧⌥=` and `⇧⌥-` change the effort only.
- Agents: Claude Code, Codex, Grok, Cursor Agent, Antigravity, OpenCode.
- Terminals: Ghostty, Orca, iTerm2, WezTerm, kitty, and tmux inside Orca, iTerm2, WezTerm and kitty.
- Settings window for presets, modifier keys and permissions.
- Command line tool `slashcommand` (`apply`, `effort`, `run`, `where`, `doctor`, `list`, `plan`).
- Nine interface languages.
