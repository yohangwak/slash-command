# Slash Command

**Switch your coding agent's model and effort with one hotkey, without leaving the conversation.**

[한국어](README.ko.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [Español](README.es.md)

Slash Command is a macOS menu bar app. Press **⇧⌥1 … ⇧⌥9** in your terminal and the agent in the frontmost session switches to that preset's **model + effort**. **⇧⌥=** and **⇧⌥-** move the effort one level up or down.

It works with **Claude Code, Codex, Grok, Cursor Agent, Antigravity and OpenCode**, in **Ghostty, Orca, iTerm2, WezTerm and kitty**.

- **One keystroke** instead of typing `/model`, finding the row, and setting the effort.
- **Mid-conversation.** Whatever you were typing stays in the input box.
- **This session only.** The defaults for your new sessions stay as they were.
- **One number, every agent.** Preset 1 can mean Opus in Claude Code and a GPT model in Codex. The app looks at which agent is in front.
- **Careful by design.** It sends keys only when it can see the agent's input box, and it stops when it is unsure.

## Install

Requires macOS 13 or later.

1. Download `Slash-Command.zip` from the [latest release](https://github.com/yohangwak/slash-command/releases/latest), unzip it, and move **Slash Command** to your Applications folder.
2. Open it. A `/` key icon appears in the menu bar.
3. Open **Settings…** from that icon and use the **Permissions** box at the top. Its buttons open the right pane of System Settings for you.

| Permission | Why |
|---|---|
| **Accessibility** (macOS 27 lists it as *Device Control and Data Access*) | Reading the Ghostty screen, and checking that iTerm2's Broadcast Input is off |
| **Automation** (Slash Command → Ghostty, Slash Command → iTerm2) | Typing into the terminal. macOS asks the first time you press a hotkey there |

WezTerm and kitty need neither, and Orca works without them. kitty needs its remote control turned on. See [Terminals](docs/terminals.md).

To start it at login, turn on **Open at login** under **General** in Settings.

<details>
<summary>Build from source</summary>

```sh
git clone https://github.com/yohangwak/slash-command.git
cd slash-command
./scripts/build-app.sh --install   # builds, copies to ~/Applications, links ~/.local/bin/slashcommand
```

You need the Swift toolchain (Xcode or the Command Line Tools). Without a signing certificate the build is ad-hoc signed, and macOS asks for the permissions again after every rebuild.

</details>

## Use

| Keys | What happens |
|---|---|
| `⇧⌥1` … `⇧⌥9` | Switch the frontmost agent to that preset's model and effort |
| `⇧⌥=` / `⇧⌥-` | Keep the model, raise or lower the effort one level |

A small notice at the bottom of the screen shows what the agent answered, for example `Opus 5.5 · high`. The hotkeys are active only while a supported terminal is in front, so the same keys keep their usual meaning in other apps. You can change the modifier keys in Settings.

The menu bar icon shows the agent in the frontmost session and what each preset would do for it.

## Presets

Edit presets under **Settings… → Presets**, or edit `~/.config/slashcommand/presets.json` directly.

```json
{
  "version": 1,
  "slots": [
    { "claude": { "model": "opus",   "effort": "high" }, "codex": { "model": "gpt-6-astra", "effort": "high" } },
    { "claude": { "model": "sonnet", "effort": "high" }, "codex": { "model": "gpt-6.1-sol", "effort": "high" } },
    { "name": "Overnight", "claude": { "model": "fable", "effort": "max" } }
  ]
}
```

A preset number is an intent. Each preset holds one entry per agent, and a hotkey uses the entry for the agent that is in front. A preset with no entry for that agent does nothing there. See [Presets](docs/presets.md) for every key.

## Command line

The app ships a command line tool with the same switching logic.

```sh
slashcommand list              # the presets
slashcommand where             # the frontmost terminal and its agent
slashcommand doctor --screen   # check the target, screen reading and input box; sends nothing
slashcommand apply 2 --trace   # apply preset 2 and print the time per step
slashcommand run 2 claude      # open a new session with preset 2
```

## What is supported

| Terminal | Notes |
|---|---|
| Ghostty | Needs Accessibility and Automation. tmux inside Ghostty is not supported yet |
| Orca | No setup. Accessibility is optional and makes a tab switch register at once |
| iTerm2 | Needs Automation, and Accessibility to check Broadcast Input |
| WezTerm | No setup |
| kitty | Turn on remote control first |
| tmux | Inside Orca, iTerm2, WezTerm and kitty |

Terminal.app and the VS Code terminal are not supported.

| Agent | Versions checked |
|---|---|
| Claude Code | 2.1.283 – 2.1.296 |
| Codex | 0.156.0 – 0.162.0 |
| Grok | 1.0.46, 1.0.50 |
| Cursor Agent | 2026.10.01 |
| Antigravity | 1.3.1, 1.3.3 |
| OpenCode | 1.18.35, 2.0.25 |

Slash Command drives each agent's own model picker by reading the screen, so it depends on the text those pickers show. When an agent changes that text, switching stops and sends nothing further. `slashcommand doctor` tells you when the version you run has not been checked.

## Privacy

Slash Command has no network code. It reads the terminal screen only to decide what to send. Its log (`~/Library/Logs/SlashCommand/slashcommand.log`) records the keys you pressed, the result and the timings. It never records what was on the screen.

## Documentation

- [Presets](docs/presets.md): the presets file and opening new sessions with `run`
- [Terminals](docs/terminals.md): setup and limits for each terminal, and tmux
- [Agents](docs/agents.md): how each agent is switched and what happens to its defaults
- [How it works](docs/how-it-works.md): detection, the picker, confirmation dialogs, timings
- [Safety and limits](docs/safety.md): the rules the app follows before it sends a key
- [Development](docs/development.md): building, testing, adding a language

## Languages

The app follows your system language. It ships in English, Korean, Japanese, Simplified Chinese, Spanish, French, German, Portuguese and Arabic. Every language except English and Korean is machine translated, and corrections are welcome.

## Contributing

Bug reports, fixes for new agent versions and translation corrections are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)

Slash Command is an independent project. It is not affiliated with Anthropic, OpenAI, xAI, Cursor, Google, OpenCode, or the makers of the terminals it supports. Their product names are used only to describe compatibility.
