# Changelog

Notable changes to Slash Command. Versions follow [Semantic Versioning](https://semver.org).

## 0.2.1

- The presets file accepts `ctrl`, `alt`, `opt` and `cmd` as modifier names (`alt` is Option on a Mac), in any letter case.
- Korean: particles after names and values are attached and use the forms that fit either ending (`이(가)`, `을(를)`).
- Codex: the first switch in a fresh session works again. The welcome text's `/model - choose what model …` line was taken for the command popup, so Enter went out too early, the picker never opened and `/model` was left in the input box.
- Ghostty + Claude Code: the second command (`/effort`) is sent only after a fresh screen shows the input box again, preventing Enter from reaching a dialog that opened in between.
- A timed-out switch no longer quotes unrelated conversation output in the error message or log; only a reply directly below our command is quoted.
- Presets whose model or effort contains a control character are refused before any key is sent.
- Antigravity: the confirming Enter is sent only after re-reading the picker and seeing the cursor on the wanted row.
- tmux: a pane in copy mode (or any other mode) is not written to.
- iTerm2: lines that wrap early because a wide character does not fit at the end of a row are counted correctly.
- A child process that leaves a background process holding its output no longer blocks the app.
- Restoring Grok, Cursor, Antigravity and OpenCode defaults keeps symlinks and file permissions; an unparseable JSON defaults file stops the switch before any key is sent.
- `slashcommand`: a target option without a value, an unknown option, an unknown `--agent` name or a non-positive `--lines` is an error instead of falling back to the frontmost session; `--dump` reports a failed write.
- Unrecognized modifier names in the presets file are reported in the menu; saving more than nine presets is refused.
- Menu: the unsupported-app header names all supported terminals; the permission button says it opens System Settings.
- VoiceOver: notices are announced, and icon-only buttons and unlabeled fields in Settings have labels.
- Windows: a CI workflow builds and tests on every pull request and push to main; the release workflow runs the tests before packaging.

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
