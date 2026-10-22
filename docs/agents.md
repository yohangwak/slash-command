# Agents

A preset holds one entry per agent. The app uses the entry for the agent in the frontmost session and ignores the rest.

| Agent | How it is switched | Defaults for new sessions | Typical time |
|---|---|---|---|
| Claude Code | `/model` picker: move to the model row, set the effort, confirm with `s` (this session only) | Not touched | 0.1 – 0.35 s in Orca |
| Codex | `/model` picker, confirm with `s` (this session only) | Not touched | 0.15 – 0.3 s in Orca |
| Grok | One line: `/model <model> <effort>` | Grok saves two keys under `[models]` in `~/.grok/config.toml`. The app puts them back | about 0.35 s |
| Cursor Agent | `/model` list: type the name one character at a time to filter, then Tab to set the Effort parameter | Cursor saves four model keys in `cli-config.json`. The app puts them back | 0.7 – 1.3 s |
| Antigravity | `/model` picker cursor and the Effort slider (←/→) | Antigravity saves `model` in its `settings.json`. The app puts it back | about 0.5 s |
| OpenCode | `/models` dialog filtered by "name + provider", then `/variants` | OpenCode saves `recent` and `variant` in `model.json`. The app puts them back | 0.4 – 0.7 s (2.x: 1.1 – 2.4 s) |

Times are measured in Orca or tmux. Other terminals add their own cost. See [Terminals](terminals.md).

## "This session only"

Claude Code and Codex have a way to confirm a choice for the current session only, and the app always uses it.

The other four agents save the choice as the default for new sessions. With `keepDefaults` on, which is the default, the app restores **only the model keys that agent just wrote** to the values they had before the switch. Every other key in the file is left alone, including changes another session made to them in the meantime. The running session keeps its new model.

One case is not protected: if another session changes those same model keys during the second or two a switch takes, the restore puts the earlier values back over that change.

- If the defaults file did not exist before the switch, the keys are removed again afterwards.
- If the file exists but cannot be read, the app does not know what to restore, so it sends nothing.
- OpenCode's file location follows the session's own `XDG_STATE_HOME`. If the app cannot narrow that down, it stops.
- Turn `keepDefaults` off to let the switch change the defaults too.

## When the app sends nothing

Claude Code and Codex need only a visible input box. They can be switched while they work, and the app sets your draft aside and brings it back; see [How it works](how-it-works.md).

Grok, Cursor Agent, Antigravity and OpenCode are switched only when the input box is empty and the agent is idle. If you have text in the box, or the agent is working, nothing is sent.

Each of those four marks "working" differently, and the app reads that marker:

| Agent | Working marker |
|---|---|
| Grok | `Ctrl+c:cancel` in the hint line, or a status line above the input box (`⠹ … [stop]`) |
| Cursor Agent | A spinner above the input line, or `ctrl+c to stop` |
| Antigravity | `esc to cancel` in the hint line |
| OpenCode | `esc interrupt` under the box |

After typing a command, the app checks that the text is visible in the input box before it sends Enter. If the text did not arrive, it stops.

## Versions

Slash Command reads each agent's screen, so a new agent version can change what it sees. These versions have been checked on a real session:

| Agent | Checked |
|---|---|
| Claude Code | 2.1.283, 2.1.288, 2.1.289, 2.1.291, 2.1.292, 2.1.296 |
| Codex | 0.156.0, 0.160.0, 0.160.1, 0.162.0 |
| Grok | 1.0.46, 1.0.50 |
| Cursor Agent | 2026.10.01 (14929f9, e373342) |
| Antigravity | 1.3.1, 1.3.3, 1.4.5 |
| OpenCode | 1.18.35, 2.0.25 |

`slashcommand doctor` reports the installed and running versions and flags any that are not on this list. An unchecked version is not known to be broken. If its screen text has changed, switching stops instead of guessing.

## Notes per agent

**Claude Code.** After a reply, changing the model or effort brings up a confirmation dialog. See [How it works](how-it-works.md#claude-codes-confirmation-dialog). In a low window the picker folds rows into `… +N models`; the app moves the cursor to the top and walks down to find the row, which takes 2 to 3.5 seconds in a 14-line window. In an 11-line window the picker's hint line is cut off; the app closes the picker and uses the command form for presets, and reports "the window is too low" for effort changes.

**Codex.** The order of models in the picker is computed from `~/.codex/models_cache.json`. The tenth model onward cannot be chosen with a number key. In a pane as narrow as 38 columns the picker's lines wrap; the app joins neighbouring lines.

**Grok.** In windows of 20 lines or fewer the hint line does not change while Grok works, so the status line above the input box is used instead.

**Cursor Agent.** Only the Effort parameter is changed. Context and Fast are left as they are. Opened with `--yolo`, the model line gains `Run Everything` on the right; the app reads the model line up to that point. The list shows ten rows at a time, so the app filters by name and picks only an exact match when several names overlap.

**Antigravity.** After long output the input box is sometimes not redrawn until Ctrl+L. The app then reports that the input box is not visible and stops.

**OpenCode.** The cursor in the model list is shown by colour only, which the app cannot read. It counts down from the top of the filtered rows to the row that equals the preset, then checks that the model line under the input box matches. With a single provider, OpenCode 2.x filters by model name only and shows no provider column; the app first works out the provider from the dialog and picks by name only when the preset ends with that provider. A model without variants (Big Pickle, for example) shows "No variants available"; the preset sets the model and says so.
