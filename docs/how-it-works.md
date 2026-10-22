# How it works

1. **Hotkey.** A global Carbon hotkey, matched by key position, so it works whatever input source is active. The hotkeys are registered only while a supported terminal is the frontmost app. In any other app the same keys do what they always did.
2. **Find the target.** The app works out which terminal session is in front and which agent is running in it. Each terminal has its own way; see [Terminals](terminals.md). The agent is identified from the processes running on that terminal, or from the window title where that is all there is.
3. **Check the input box.** The app reads the screen and continues only when the agent's input box is visible at the bottom. See [Safety and limits](safety.md).
4. **Switch.** The app opens the agent's own model picker and drives it while reading the screen: it reads which row the cursor is on, moves exactly that far, reads again to confirm it arrived, and confirms with "this session only".
5. **Report.** The notice shows what the agent itself answered, read from the line under the command just typed.

Text and keys are written to the terminal as bytes (Ghostty `perform action "text:…"`, Orca's runtime socket, `wezterm cli send-text --no-paste`, `kitty @ send-text`, iTerm2 `write text`, `tmux send-keys`). They are not synthetic keyboard events, so they cannot land in another app. On Windows, Windows Terminal panes get key records written into the pane's own console; see [Terminals](terminals.md#windows).

## Claude Code and Codex

- **Claude Code:** move the cursor to the model row, set the effort line (`● High effort ←/→`) to the target level, confirm with `s`. The answer (`Set model to Opus 5.5 for this session only with high effort`) goes into the notice.
- **Codex:** choose the model with a number key and the effort with the cursor. Choosing the effort with a number key would save it as the default. `max` and `ultra` are found under "More reasoning…".
- **Your draft:** Claude Code stashes it with `Ctrl+S` and brings it back itself. For Codex the app moves a one-line draft to the kill buffer and yanks it back.

The other agents are described in [Agents](agents.md).

## Claude Code's confirmation dialog

When you change the model or effort in a conversation Claude Code has just replied in, it asks `Switch model?` or `Change effort level?`, because the conversation history has to be re-read.

By default the app **accepts** it, on two conditions: the dialog asks about the very value the app chose, and the cursor is on Yes. Only then does it send Enter. It sends nothing to any other dialog.

With `acceptSwitchPrompt` off, the app sends nothing to that dialog. The notice asks you to confirm with Enter, waits up to 20 seconds for your choice, then reports the result.

## When the picker cannot be used

- If Claude Code's picker has no row for the model (an older model, a custom id), the app closes the picker and uses the `/model X` and `/effort Y` commands. Those commands also change the defaults for new sessions in `~/.claude/settings.json`, so the app captures the file first and afterwards restores only the default entries.
- **Claude Code in Ghostty always uses the command form.** Ghostty's screen text is up to half a second old, so confirming every picker step would take 2.4 to 3.8 seconds. Instead the app takes "Claude Code rewrote its settings file" as the sign that the command ran. For a command that does not rewrite the file (`/effort max` applies to the session only), it waits for a fresh screen and reads the answer line. Before the second command the app waits for a fresh screen that shows the input box.
- In Ghostty, when the title names no agent and two agents run in the same folder, the app tells them apart by which input box is on screen.

## Timings

Measured on 2026-10-06 with Claude Code 2.1.283 – 2.1.289, Codex 0.156.0 – 0.160.1, Orca 1.4.220 and Ghostty 1.3.1. Other terminals are in [Terminals](terminals.md).

| | First version | Now |
|---|---|---|
| Orca, Claude Code | 6.4 s | 0.08 – 0.35 s |
| Orca, Codex | 2.65 s | 0.15 – 0.30 s |
| Orca, one effort step | | 0.1 – 0.4 s |
| Orca, finding the frontmost terminal | 0.45 s | 0.07 – 0.10 s |
| Ghostty, Claude Code | | about 0.6 s to the notice |
| Ghostty, Claude Code, one effort step | | 1.8 – 2.5 s |
| Ghostty, Codex | | 3.0 – 4.6 s |

The input-box check between the two Claude Code commands in Ghostty adds about 0.6 s: on 2026-10-22 (Claude Code 2.1.302, Ghostty 1.3.1, four runs each) a whole switch took 1.53 s without it and 2.10 s with it.

What made it faster: fixed waits (4.9 s) replaced by reading the screen, the `orca` command (0.2 s a call) replaced by the app's socket (under 1 ms), `ps` and `osascript` child processes replaced by in-process calls.

`slashcommand apply <number> --trace` prints the time each step took.

## Code layout

| Target | What it holds |
|---|---|
| `SlashCommandCore` | Presets, detection, terminal I/O, reading the screen, the step runner, restoring defaults |
| `slashcommand` | The command line tool |
| `SlashCommandApp` | Menu bar item, hotkeys, notices, the Settings window |
| `SlashCommandWin` | Windows tray app |
| `CWindowsTerminal` | UI Automation and console access in C |

The contract a terminal connection has to meet is in [CONTRACT.md](CONTRACT.md).
