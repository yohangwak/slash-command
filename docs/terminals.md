# Terminals

The hotkeys work when one of these apps is in front: **Ghostty, Orca, iTerm2, WezTerm, kitty**. They also follow **tmux** running inside Orca, iTerm2, WezTerm or kitty.

Not supported: Terminal.app, the VS Code terminal, Orca's floating terminal, and tmux inside Ghostty.

| Terminal | Accessibility | Automation | Other setup | Typical time for a switch |
|---|---|---|---|---|
| Orca | Optional | No | None | 0.1 – 0.4 s |
| WezTerm | No | No | None | about 0.3 s |
| kitty | No | No | Remote control on | about 0.7 s |
| iTerm2 | Yes | Yes | None | 1.3 – 2.6 s |
| Ghostty | Yes | Yes | None | 0.6 – 4.6 s, see below |

## Ghostty

Slash Command reads the frontmost terminal's id, title and folder over AppleScript, and reads the screen through Accessibility.

Ghostty hands out screen text that is up to half a second old. Every step that has to confirm what is on screen therefore costs half a second, which is why a Codex switch takes 3 to 4.6 seconds here. For Claude Code the app uses the `/model` and `/effort` commands instead of the picker and takes about 0.6 seconds. See [How it works](how-it-works.md#when-the-picker-cannot-be-used).

Ghostty 1.3.1 does not expose a terminal's tty, so tmux inside Ghostty cannot be followed yet.

## Orca

The app reads which workspace is on screen from Orca's state database, and writes through Orca's runtime socket, falling back to the `orca` command. Neither is a public interface. If their format changes, the app fails instead of guessing.

Right after you switch tabs, Orca's state lags the window by 1.3 to 2.5 seconds. With Accessibility granted, the app reads the tab strip instead and knows the visible tab at once. Without it, a hotkey pressed in that window of time can go to the tab you just left. If two workspaces have the same tab titles in the same order, the app cannot tell them apart and sends nothing.

## iTerm2

The app finds the session of the frontmost window over AppleScript, writes with `write text … newline NO`, and reads with `contents`. macOS asks once whether Slash Command may control iTerm.

**Broadcast Input.** When Shell ▸ Broadcast Input is on, text written over AppleScript also goes to the other panes. Before every write the app reads that menu through Accessibility and sends only when "Send Input to Current Session Only" is checked. If broadcasting is on, or the menu cannot be read, it sends nothing and says so. A gap of a few tens of milliseconds remains between that check and the write.

`contents` includes the scrollback, so the app keeps only the lines that are on screen now. It counts rows using the profile's "Ambiguous characters are double-width" setting. A setting changed for one session only (Edit Session…) cannot be seen, so the app accepts "the input box is visible" only when that holds for both widths.

Checked with iTerm2 3.7.3. tmux integration mode (`tmux -CC`) has not been checked.

## WezTerm

Nothing to set up. The app asks `wezterm cli` for the focused pane and its tty. With several WezTerm instances running, it uses the socket of the frontmost one.

## kitty

Turn on remote control in `kitty.conf`:

```
allow_remote_control socket-only
listen_on unix:/tmp/kitty
```

Or start kitty with `kitty --listen-on unix:/path`.

Any program that can reach that socket can type into kitty's windows and read their screens. If you do not want that, leave it off. The app then tells you remote control is off and stops.

The app does not guess the socket from the config file. It takes the socket the frontmost kitty process actually has open, so `--config`, `include`, `~` and environment variables in the address all work.

## tmux

When the frontmost pane of Orca, iTerm2, WezTerm or kitty is running a tmux client, the app goes to the tmux pane that client is showing, and reads and writes through tmux.

- A pane in copy mode is not written to. The same applies to any other pane mode.
- A client suspended with `suspend-client` or Ctrl-Z is not followed. The screen is showing the shell.
- If the window has `synchronize-panes` on, the text would go to the other panes too. The app sends nothing and says so.
- In Orca, a tmux client counts as belonging to a terminal only when it was started in that terminal itself, not from inside a tmux pane.

## Naming a target yourself

The command line tool can address a terminal that is not in front, or one the hotkeys cannot find:

```sh
slashcommand apply 2 --tmux <pane> [--tmux-socket <name or path>] --agent claude
slashcommand apply 2 --kitty <window id> --kitty-socket unix:/path --agent codex
slashcommand apply 2 --wezterm <pane id> --agent codex
slashcommand apply 2 --iterm <session unique id> --agent claude
slashcommand apply 2 --orca <handle> --agent claude
slashcommand apply 2 --app windowsterminal
slashcommand apply 2 --console <pid> --agent codex
slashcommand where --bundle com.mitchellh.ghostty   # as if that app were in front
```

## Windows

The Windows app supports **Windows Terminal, Orca and WezTerm**. Nothing needs to be set up, and no permission is asked for.

Orca is supported when installed in `%LOCALAPPDATA%\Programs\orca`.

| Terminal | How the pane is found | How keys are written | Not supported |
|---|---|---|---|
| Windows Terminal | The pane with keyboard focus (UI Automation), matched to the one console among Windows Terminal's shells that shows the same text | Key records written into that pane's own console by a helper process (`slashcommand.exe`). They reach that pane only, whichever pane has focus | A pane handed over from outside Windows Terminal, identical screens in two panes, Windows Terminal running as administrator |
| Orca | Orca's runtime named pipe | The same pipe | — |
| WezTerm | `wezterm cli list-clients` of the frontmost WezTerm window | `wezterm cli send-text --no-paste` to that pane | Panes running WSL, tmux or SSH, and panes of SSH or mux domains |

- **Windows Terminal never receives synthetic keyboard input or window messages from the app.** Its window input follows focus and its "broadcast input" copies keys to every pane of a tab, so the app writes to the pane's console instead.
- **WezTerm** on Windows does not say which program runs in which pane, so the agent is told from the screen, and the app checks that an agent of that kind runs under that WezTerm window and that nothing there runs WSL, tmux, SSH or a container. Because it still cannot prove that the pane runs on this computer, Grok, Cursor Agent, Antigravity and OpenCode, which save the choice as their default, switch in WezTerm only with `keepDefaults` off.
- In Windows Terminal, Shift+Alt+= and Shift+Alt+- are also the default "Duplicate pane" keys. While Windows Terminal is in front, Slash Command takes them.
