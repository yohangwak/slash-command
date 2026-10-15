# Presets

A preset is a number from 1 to 9. Each preset holds one entry per agent: the model and the effort to switch to. The hotkey for a number uses the entry for whichever agent is in the frontmost session.

Edit presets in **Settings… → Presets**. Presets are collapsed to one line each. Expand one to set the model and effort per agent, and use **Add Agent** to add only the agents you use. Unsaved edits survive closing and reopening the window.

## The presets file

The file is `~/.config/slashcommand/presets.json`. Set `SLASHCOMMAND_CONFIG` to use another file. `slashcommand path` prints the one in use.

```json
{
  "version": 1,
  "keepDefaults": true,
  "acceptSwitchPrompt": true,
  "effortKeys": true,
  "modifiers": ["option", "shift"],
  "slots": [
    { "claude": { "model": "opus",   "effort": "high" }, "codex": { "model": "gpt-6-astra", "effort": "high" } },
    { "claude": { "model": "sonnet", "effort": "high" }, "codex": { "model": "gpt-6.1-sol", "effort": "high" } },
    { "name": "Overnight", "claude": { "model": "fable", "effort": "max" } }
  ]
}
```

| Key | Default | Meaning |
|---|---|---|
| `slots` | required | The presets, in order. The first is preset 1 |
| `modifiers` | `["option", "shift"]` | The keys held with the number. Any of `control`, `option`, `shift`, `command`. Shift alone is not accepted, because you could no longer type `!` `@` `#` |
| `effortKeys` | `true` | Whether `=` and `-` with the same modifiers change the effort |
| `keepDefaults` | `true` | Change this session only. See [Agents](agents.md) for what that means per agent |
| `acceptSwitchPrompt` | `true` | Accept Claude Code's confirmation dialog automatically. See [How it works](how-it-works.md#claude-codes-confirmation-dialog) |

Keys the app does not know are kept when it saves the file, so a file written by a newer version survives an older one.

### A slot

| Key | Meaning |
|---|---|
| `name` | Optional label shown in the menu and the list |
| `claude`, `codex`, `grok`, `cursor`, `antigravity`, `opencode` | `{ "model": …, "effort": … }` for that agent. Leave an agent out and the preset does nothing in that agent |

### Model and effort values

The model is the name the agent shows on screen. Case and punctuation are ignored, so `claude-opus-5-5` and `Claude Opus 5.5` are the same.

| Agent | `model` | `effort` |
|---|---|---|
| Claude Code | An alias (`fable`, `opus`, `sonnet`, `haiku`: the latest of that family), the name in the picker (`Opus 5`), or a full model id (`claude-opus-5`) | `low`, `medium`, `high`, `xhigh`, `max` |
| Codex | The slug of a model shown in the `/model` picker | `low`, `medium`, `high`, `xhigh`, `max`, `ultra`, as far as the model supports them |
| Grok, Cursor Agent, Antigravity | The model name shown in that agent's picker | The effort names that agent shows |
| OpenCode | The model name followed by its provider, as the `/models` dialog shows the row | The variant name. A model without variants ignores it |

## Opening a new session with a preset

```sh
slashcommand run 2 claude    # runs: claude --model … --effort …
slashcommand run 2 codex --dry-run   # print the command instead of running it
```

`run` works for every supported agent. Some details differ:

- **Cursor Agent, Antigravity, OpenCode** take a model id, not the on-screen name. `run` looks the id up in that CLI's model list (`cursor-agent models`, `agy models`, `opencode models --verbose`). If the list cannot be read or the name is not in it, nothing is opened.
- **Cursor Agent** saves the model it was opened with as the default for new sessions. With `keepDefaults` on, `run` watches for one minute and puts the previous default back if it changed to the opened model. A change another session made to a different model is left alone.
- **OpenCode 1.x** has no option for the variant, so only the model is set.
- **OpenCode 2.x** has no `--model` option. `run` opens it, waits for its input box in this terminal (up to 30 seconds), then performs the same switch a hotkey would. The result goes to the log file. This needs a terminal the session can identify from its environment: a tmux pane, Orca, iTerm2, WezTerm, or kitty with remote control on. It is not available in Ghostty.

## Other commands

```sh
slashcommand list                # the presets
slashcommand plan 1 codex        # print the keys that would be sent; runs nothing
slashcommand apply 2 --trace     # apply preset 2, print the time per step
slashcommand effort up           # keep the model, raise the effort one level
```

`slashcommand` with no arguments prints the full usage, including how to name a target terminal directly.

Installing with Homebrew links the tool as `slashcommand`. An install from the zip does not put it on your `PATH`: the tool is `Slash Command.app/Contents/MacOS/slashcommand-cli`, and the [README](../README.md#command-line) shows how to link it.
