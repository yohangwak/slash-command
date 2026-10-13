# Safety and limits

Slash Command types into a terminal where an agent may be holding a permission prompt, an approval dialog, or a running task. A stray Enter there can accept something you did not choose. These are the rules it follows.

## Rules

- **No visible input box, nothing sent.** The test is "the input box is visible", not "no dialog is open". An Enter sent while a permission or approval dialog is up would press that dialog's default choice.
- **Cannot read the screen, nothing sent.** There is no path that sends without checking first.
- **No decisions on a stale screen.** In Ghostty the first decision is made only on a screen newer than Ghostty's half-second cache.
- **Read and write the same terminal.** If the focus moved between reading and writing, the app does not write.
- **Esc only while the picker the app opened is on screen.** In a working agent, Esc interrupts the task.
- **Pickers and input boxes count only at the bottom of the screen.** A picker is recognised only when the last line is that picker's own hint line (`s to use this session only`, `esc back`), reading upward from there. Text in the conversation that looks like a picker is never read. Approval dialogs use numbered rows too, but their hint text differs.
- **Success means the agent's answer to the command just typed.** A changed settings file is not proof, because other sessions write that file too.
- **No wrapping around.** An effort step is not sent at the end of the range. Claude Code's picker wraps to the other end. In Claude Code the app confirms only when the cursor is on the model in use (`✔`).
- **The notice quotes the agent.** The result text is read from the line under the last command, or from the notice line above the input box while the agent works. Older result lines still on screen are not read.
- **Screen text is never logged.** Prompts, code and secrets are on that screen. The log holds the keys pressed, the preset, the result sentence and the timings.
- **When unsure, stop.** If the wording on screen has changed or the model row is missing, the app sends no key, or closes only the picker it opened. It does not try other keys to see what happens.

Narrow windows are handled: rows whose description wraps to the next line are read at 62 and 58 columns, and Codex down to 38 columns.

## Limits

- **Screen wording.** The app relies on the English text the agents show. A change in that text stops switching. `slashcommand doctor` reports versions that have not been checked. See [Agents](agents.md#versions).
- **Orca internals.** The visible workspace comes from Orca's state database and writes go through its runtime socket. Neither is a public interface.
- **Orca, right after a tab switch.** Without Accessibility, the app can target the previous tab for 1.3 to 2.5 seconds. The active split of a split pane still comes from Orca's terminal list.
- **Ghostty and Codex.** A switch takes 3 to 4.6 seconds, because Ghostty's screen text is cached for half a second and no other accessibility attribute returns a fresher copy.
- **iTerm2 Broadcast Input.** A few tens of milliseconds pass between the check and the write. Turning broadcasting on in that gap is not caught.
- **Claude Code, command form.** Claude Code answers `Set effort level to high` even for a model without effort levels (Haiku). The notice repeats what Claude Code said.
- **Several displays.** The notice appears on the main screen. Whether that is always the screen holding the terminal has not been checked.
- **Not supported:** Terminal.app, the VS Code terminal, Orca's floating terminal, tmux inside Ghostty, iTerm2's tmux integration mode.

Per-terminal and per-agent limits are in [Terminals](terminals.md) and [Agents](agents.md).
