# Contract

What a terminal connection has to guarantee, and what the product promises. Use this when adding a terminal or changing the step runner.

## 1. What a terminal connection (`TerminalIO`) must do

| Operation | Contract | Why |
|---|---|---|
| `type` / `press` | Put in exactly those bytes. Do not wrap them in bracketed-paste markers (`ESC[200~`) | WezTerm wraps by default (`--no-paste` is required). Wrapped text reaches the agent as a paste, not as keys |
| Write failure | Return a failure when the write certainly did not happen. **Even after a success, do not assume the bytes arrived** | kitty `send-text` returns success (0) for a window that does not exist, so check with `ls` that the window is there before writing |
| `screen` | The lines read, or "could not read". An empty screen and an unreadable one are different | Unreadable means nothing is sent |
| `snapshot` / `freshSnapshot` | A read that is guaranteed to be current. If the source is cached, report `screenLagMs` | Ghostty's accessibility text is a half-second-old copy. Trusting it once sent Enter into an open picker |
| Target of read and write | The same terminal. If the focus changed, do not write | If the screen read and the place written differ, the input-box check means nothing |
| Extent of the screen | Only the lines on screen now. With scrollback mixed in (iTerm2 `contents`), an old input box above a cleared screen reads as the current one | Reproduced with `contents` returning 88 lines for a 25-line screen |
| `draft` | Read the user's unsent text where possible and leave it as it was | A switch must not erase what the user typed |

## 2. What the product promises (`Runner`)

1. **Send only when the input box is visible at the bottom.** Not on an approval dialog, a picker, or a working screen. The test is "the input box is visible", not "no dialog".
2. **A picker counts only when the last line of the screen is its hint line** (`s to use this session only`, `esc back`, and so on). Text in the conversation that looks like a picker is not read.
3. **Esc only while the picker we opened is visible.** In a working agent, Esc is an interrupt.
4. **Leave the defaults alone.** Confirm with "this session only" (`s`). Do not use Enter or a number key where that saves the default. When the command form (`/model X`) is unavoidable, capture the defaults file first, restore it afterwards, and verify by hash.
5. **Proof of success is the on-screen answer to the command we typed.** The defaults file is written by other sessions too, so it is not proof. The result text in the notice is read only from the answer under the last command.
6. **Confirmation dialogs** (Claude Code's "Switch model?" and "Change effort level?") are accepted only when `acceptSwitchPrompt` is on, the value asked about is the value we chose, and the cursor is on Yes. Otherwise tell the user and wait 20 seconds. If the user handles it in that time, continue.
7. **When unsure, stop.** If the wording changed or the model row is missing, send no key (outside a picker) or close only the picker we opened. Never probe with other keys.
8. **Never log screen text.** Log the hotkey, the preset, the result sentence the agent gave, and the time per step. The screen holds prompts, code and secrets.

## 2′. Extra rules for the Grok, Cursor, Antigravity and OpenCode drivers

- **Enter only after the text is visible.** After typing a command, confirm it shows in the input box before sending Enter, so that Enter cannot land elsewhere when the box is not taking input (OpenCode after a long answer, Cursor treating a burst as a paste).
- **One character at a time.** Cursor treats text sent in one burst as a paste and ignores it. Type filters character by character.
- **When the cursor is not shown as a character, count rows.** OpenCode marks the list cursor by colour only. Count down from the top filtered row to the row equal to the preset, then verify the model line afterwards.
- **Each agent marks "working" its own way.** An empty-looking input box can belong to a working agent (Grok `Ctrl+c:cancel`, Cursor's spinner, Antigravity `esc to cancel`, OpenCode `esc interrupt`). An unknown hint line is not "idle".
- **Restore only those keys.** With `keepDefaults` on, restore only the model keys to their values from before the switch, and look once more 250 ms later. Leave other keys and other sessions' writes alone.
- **Do not press past the end.** Compute the neighbour from the list of levels and go only there, so that a slider or radio group does not wrap or move to another row (Cursor's Fast switch, for example).

## 3. Known limits (outside the contract)

- How "the frontmost terminal" is found differs per terminal. See [Terminals](terminals.md).
- Orca's visible tab: the state database and `terminal.list` lag 1.3 to 2.5 seconds after a change. With Accessibility, the tab strip in the accessibility tree is matched against the order of tab titles in the terminal list, with no lag. If that cannot be read or no workspace matches, the database is used, with the lag. If two workspaces have the same tab-title order, nothing is sent. A hidden terminal also has an input box, so "the input box is visible" is not proof that the terminal is visible.
- The app relies on the agents' on-screen wording. `slashcommand doctor` reports checked versions (`AgentVersions.tested`). An unchecked version means "not verified", not "broken". If the wording changed, rule 7 applies.

## 4. Checking a new version or a new terminal

1. `slashcommand doctor`: target, version, screen reading, input box state. It sends nothing.
2. Open a separate test session. Never send test input to a session doing real work. Test only with values equal to the current defaults, and compare the agent's defaults file with a copy taken before the test.
3. When it passes, add the version to `AgentVersions.tested` and to the table in [Agents](agents.md#versions).
