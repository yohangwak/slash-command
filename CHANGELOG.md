# Changelog

Notable changes to Slash Command. Versions follow [Semantic Versioning](https://semver.org).

## 0.2.3

- `slashcommand apply` and `effort` refuse options they do not read, so `apply 2 --dry-run` no longer switches (only `run` has `--dry-run`). A repeated option, two target options, `--agent` or a socket option without a target option, and the Windows-only `--app` and `--console` on a Mac are refused instead of being ignored.
- Claude Code: when `~/.claude/settings.json` did not exist, the file that `/model` creates is removed again after the switch, so the default for new sessions stays as it was. An unreadable or non-JSON settings file stops the switch before any key is sent.
- The log file no longer holds text read from the screen or a window title: error messages quote it in the notification, and the log gets a placeholder instead. The log folder and files are private to you (0700 and 0600, also for those an earlier version made), and the CLI's log is rotated at 2 MB like the app's.
- Grok: a conversation line containing "not available" is no longer taken for Grok refusing the model.
- Presets whose model or effort contains a backslash or a C1 control character are refused before any key is sent.
- "Press Enter to confirm" stays on screen when a hotkey is pressed again while Claude Code asks to switch.
- Keys in the presets file that this version does not use (a misspelt name, say) are named in the menu and by `slashcommand list`.
- Settings shows the actual error sentence instead of a generic one.
- `slashcommand doctor --dump` writes its file with mode 0600 and says that it holds the screen and your draft.
- Windows: a background process that keeps a child's output open no longer blocks the tray app, and neither a reused parent process id nor a process list that ended early is trusted when finding the agent.

## 0.2.2

- Antigravity: a preset whose model is no longer offered is refused with the list of models the picker does offer, so you can fix the preset without opening the picker.
- Settings: the Antigravity model suggestions follow what Antigravity 1.4.5 offers (Gemini 4 Argon, Gemini 3.8 Flash, Claude Opus 5.5, Claude Sonnet 5.5).
- Antigravity 1.4.5 is on the checked list (`slashcommand doctor`).

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
