# Slash Command

**一个快捷键就能切换编程智能体的模型和推理强度(effort),无需离开当前对话。**

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md) · [Español](README.es.md)

Slash Command 是一款 macOS 菜单栏应用。在终端里按下 **⇧⌥1 … ⇧⌥9**,最前面会话中的智能体就会切换到对应预设的 **模型 + effort**。**⇧⌥=** 和 **⇧⌥-** 可以把 effort 调高或调低一级。

它支持 **Claude Code、Codex、Grok、Cursor Agent、Antigravity 和 OpenCode**,可在 **Ghostty、Orca、iTerm2、WezTerm 和 kitty** 中使用。

- **一次按键**,不必再输入 `/model`、找到对应的选项、再设置 effort。
- **对话进行中也能用。** 你正在输入的内容会原样保留在输入框里。
- **只作用于当前会话。** 新会话的默认设置保持不变。
- **一个编号,适用于所有智能体。** 预设 1 在 Claude Code 中可以代表 Opus,在 Codex 中可以代表某个 GPT 模型。应用会根据最前面的是哪个智能体来决定。
- **设计上很谨慎。** 只有在能看到智能体输入框时才会发送按键,拿不准时就会停下。

## 安装

需要 macOS 13 或更高版本。

1. 从[最新版本](https://github.com/yohangwak/slash-command/releases/latest)下载 `Slash-Command.zip`,解压后把 **Slash Command** 移动到“应用程序”文件夹。
2. 打开它,菜单栏中会出现一个 `/` 键图标。
3. 通过该图标打开 **设置…**,使用顶部的 **权限** 区域。其中的按钮会替你打开系统设置里对应的面板。

| 权限 | 用途 |
|---|---|
| **辅助功能**(macOS 27 中显示为 *Device Control and Data Access*) | 读取 Ghostty 的屏幕内容,并检查 iTerm2 的 Broadcast Input 是否已关闭 |
| **自动化**(Slash Command → Ghostty、Slash Command → iTerm2) | 向终端输入内容。第一次在该终端中按下快捷键时,macOS 会询问 |

WezTerm 和 kitty 两者都不需要,Orca 也无需这些权限即可使用。kitty 需要开启远程控制。参见 [Terminals](docs/terminals.md)。

如需开机登录后自动启动,请在设置的 **通用** 下打开 **登录时打开**。

<details>
<summary>从源码构建</summary>

```sh
git clone https://github.com/yohangwak/slash-command.git
cd slash-command
./scripts/build-app.sh --install   # builds, copies to ~/Applications, links ~/.local/bin/slashcommand
```

你需要 Swift 工具链(Xcode 或 Command Line Tools)。没有签名证书时,构建结果使用临时(ad-hoc)签名,每次重新构建后 macOS 都会再次请求权限。

</details>

## 使用

| 按键 | 效果 |
|---|---|
| `⇧⌥1` … `⇧⌥9` | 把最前面的智能体切换到对应预设的模型和 effort |
| `⇧⌥=` / `⇧⌥-` | 保持模型不变,把 effort 调高或调低一级 |

屏幕底部会弹出一个小提示,显示智能体的回应,例如 `Opus 5.5 · high`。快捷键只在受支持的终端位于最前面时才生效,因此在其他应用中,这些按键仍保持原有含义。你可以在设置中更改修饰键。

菜单栏图标会显示最前面会话中的智能体,以及每个预设对它会执行什么操作。

## 预设

在 **设置… → 预设** 中编辑预设,也可以直接编辑 `~/.config/slashcommand/presets.json`。

```json
{
  "version": 1,
  "slots": [
    { "claude": { "model": "opus",   "effort": "high" }, "codex": { "model": "gpt-6-astra", "effort": "high" } },
    { "claude": { "model": "sonnet", "effort": "high" }, "codex": { "model": "gpt-6.1-sol", "effort": "high" } },
    { "name": "通宵", "claude": { "model": "fable", "effort": "max" } }
  ]
}
```

预设编号代表一种意图。每个预设为每个智能体各保存一项,快捷键会使用最前面那个智能体对应的条目。如果某个预设没有该智能体的条目,它在那里不会执行任何操作。所有可用的键请参见 [Presets](docs/presets.md)。

## 命令行

应用自带一个命令行工具,使用相同的切换逻辑。

```sh
slashcommand list              # the presets
slashcommand where             # the frontmost terminal and its agent
slashcommand doctor --screen   # check the target, screen reading and input box; sends nothing
slashcommand apply 2 --trace   # apply preset 2 and print the time per step
slashcommand run 2 claude      # open a new session with preset 2
```

## 支持情况

| 终端 | 说明 |
|---|---|
| Ghostty | 需要辅助功能和自动化。暂不支持 Ghostty 内部的 tmux |
| Orca | 无需设置。辅助功能是可选的,开启后切换标签页会立即被识别 |
| iTerm2 | 需要自动化,检查 Broadcast Input 还需要辅助功能 |
| WezTerm | 无需设置 |
| kitty | 先开启远程控制 |
| tmux | 在 Orca、iTerm2、WezTerm 和 kitty 内部可用 |

不支持 Terminal.app 和 VS Code 终端。

| 智能体 | 已验证的版本 |
|---|---|
| Claude Code | 2.1.283 – 2.1.296 |
| Codex | 0.156.0 – 0.162.0 |
| Grok | 1.0.46, 1.0.50 |
| Cursor Agent | 2026.10.01 |
| Antigravity | 1.3.1, 1.3.3 |
| OpenCode | 1.18.35, 2.0.25 |

Slash Command 通过读取屏幕来操作每个智能体自带的模型选择器,因此依赖这些选择器显示的文字。当某个智能体修改了这些文字时,切换会停止,并且不再发送任何内容。如果你运行的版本尚未验证,`slashcommand doctor` 会告诉你。

## 隐私

Slash Command 不包含任何网络代码。它读取终端屏幕只是为了决定发送什么。它的日志(`~/Library/Logs/SlashCommand/slashcommand.log`)会记录你按下的键、结果和耗时,但从不记录屏幕上的内容。

## 文档

这些文档仅提供英文版本。

- [Presets](docs/presets.md):预设文件,以及用 `run` 打开新会话
- [Terminals](docs/terminals.md):各终端的设置与限制,以及 tmux
- [Agents](docs/agents.md):每个智能体如何切换,以及其默认设置会怎样
- [How it works](docs/how-it-works.md):检测、选择器、确认对话框、耗时
- [Safety and limits](docs/safety.md):应用在发送按键之前遵守的规则
- [Development](docs/development.md):构建、测试、添加语言

## 语言

应用会跟随系统语言。它提供英语、韩语、日语、简体中文、西班牙语、法语、德语、葡萄牙语和阿拉伯语版本。除英语和韩语外,其余语言均为机器翻译,欢迎提出修正。

## 参与贡献

欢迎提交缺陷报告、适配新智能体版本的修复以及翻译修正。参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)

Slash Command 是一个独立项目,与 Anthropic、OpenAI、xAI、Cursor、Google、OpenCode 以及所支持终端的开发者均无关联。文中使用这些产品名称仅为说明兼容性。
