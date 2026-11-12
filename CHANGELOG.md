# Changelog

Notable changes to Slash Command. Versions follow [Semantic Versioning](https://semver.org).

## 0.2.8

- The notice that appears after a hotkey shows its whole title on up to three lines instead of cutting it off with "…". Long titles were cut in every language, among them the English "Device Control and Data Access permission needed".
- Settings: when the presets file cannot be read, and when saving fails, the message is drawn in the normal text color with an orange warning icon. The orange text was hard to read (1.9:1 contrast on the light background).
- Settings: the explanations under Presets, Shortcut and About wrap onto more lines instead of being cut off with "…".

## 0.2.7

- Orca 1.4.257: hotkeys work again in Orca's translated interface. Orca now shows its interface in your language, and the tab strip's "Close tab" label is translated with it, so the app found no tabs and said "could not tell which Orca tab is on screen". The app now reads each tab's title and its close button by their place in the tab, not by the English words, in every language Orca offers.
- Orca: a tab the app cannot read, such as a pinned tab, is no longer skipped while the rest of the strip is matched. The hotkey sends nothing instead, so it can never reach a terminal that is not on screen.

## 0.2.6

- Orca 1.4.256: hotkeys work again. Orca changed how its tab strip marks the active tab, so the app could not see it and fell back to Orca's state database, which this Orca no longer updates when you switch. A hotkey then failed with "The frontmost Orca tab is not a terminal", or switched the model in a terminal you had left. The app now reads the new mark (and the old one) and never uses that database on a Mac.
- Orca on a Mac now needs Accessibility. Without it a hotkey sends nothing and opens the settings, instead of guessing from the stale database. The one-time "Turn on Accessibility … right after switching tabs" notice is gone.
- Orca on a Mac also needs its sidebar shown: the workspace marked as current there is the only one compared, so a hidden workspace with the same tab titles can never be picked. With the sidebar hidden, nothing is sent and the notice says so.
- Orca: a workspace with file, browser or chat tabs open is refused with a message saying so (before, the app guessed from the state database).

## 0.2.5

- Settings has an About section: the version, Report a Problem…, Questions and Ideas, and Release Notes. Report a Problem opens a new GitHub issue in the browser with the versions of Slash Command, macOS and the installed agents filled in; nothing else goes into it. GitHub receives those numbers in the page address when it opens; the issue is posted only when you submit the form. The menu has Report a Problem… too.
- Settings shows where the log file is, with Show in Finder.
- Windows: the tray menu has Report a Problem… (Slash Command's and Windows' versions filled in), and the tray icon's tooltip shows the version.

## 0.2.4

- The first time this version starts, it moves the log that an earlier version wrote (`slashcommand.log` and `.1`) to the Trash (deletes it on Windows): versions before 0.2.3 could write screen text into it. It happens once.
- Errors from tmux, kitty, WezTerm, osascript and Orca still quote what the command printed in the notification and on the command line, but the log file gets a placeholder instead, since that output can include window titles.
- Claude Code: "Switch model?" is accepted only when it is the dialog at the bottom of the screen, with no picker open; text shaped like it in the conversation is never answered. In Ghostty the dialog is read once more, past Ghostty's screen cache, right before Enter.
- Codex: the effort list for one model is no longer taken for that of a model whose name only starts the same way (GPT-6.1-Sol and GPT-6.1-Sol-Mini).
- When the screen cannot be read while a picker is being closed, the app stops instead of sending the rest of the cleanup keys. Grok stops erasing the draft when the screen cannot be read, and when the Antigravity effort slider shows no single selected step, the switch stops instead of setting only the model.
- A preset whose model is empty is refused before any key is sent, in the menu, the hotkeys and `slashcommand run` alike.
- Windows release: only a separate publish job can write to the repository; the build and tests run read-only.
- Docs: Orca on Windows can send a hotkey to the tab you just left right after a tab switch; which terminals check the focus before each write; how the end of a Claude Code effort range is found.

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
