# Slash Command

**一个快捷键就能切换编程智能体的模型和推理强度(effort),无需离开当前对话。**

[English](README.md) · [한국어](README.ko.md) · [日本語](README.ja.md) · [Español](README.es.md)

**[下载 macOS 版](https://github.com/yohangwak/slash-command/releases/latest/download/Slash-Command.dmg)** · macOS 13 或更高版本 · Apple 芯片和 Intel  
**[下载 Windows 版](https://github.com/yohangwak/slash-command/releases/latest/download/Slash-Command-Windows-x64.zip)** · Windows 11 · x64

![每按一次快捷键,Claude Code 就在 Sonnet、Fable、Opus 之间切换并提高 effort,每次变更都会显示通知](docs/assets/demo.gif)

Slash Command 是一款 macOS 菜单栏应用,也是一款 Windows 托盘应用。在终端里按下 **⇧⌥1 … ⇧⌥9**(Windows 上为 **Shift+Alt+1 … 9**),最前面会话中的智能体就会切换到对应预设的 **模型 + effort**。**⇧⌥=** 和 **⇧⌥-** 可以把 effort 调高或调低一级。

它支持 **Claude Code、Codex、Grok、Cursor Agent、Antigravity 和 OpenCode**,在 macOS 上可用于 **Ghostty、Orca、iTerm2、WezTerm 和 kitty**,在 Windows 上可用于 **Windows Terminal、Orca 和 WezTerm**。

- **一次按键**,不必再输入 `/model`、找到对应的选项、再设置 effort。
- **对话进行中也能用。** 你正在输入的内容会原样保留在输入框里。
- **只作用于当前会话。** 新会话的默认设置保持不变。
- **一个编号,适用于所有智能体。** 预设 1 在 Claude Code 中可以代表 Opus,在 Codex 中可以代表某个 GPT 模型。应用会根据最前面的是哪个智能体来决定。
- **设计上很谨慎。** 只有在能看到智能体输入框时才会发送按键,拿不准时就会停下。

## 安装

### macOS

需要 macOS 13 或更高版本。

1. 下载 [**Slash-Command.dmg**](https://github.com/yohangwak/slash-command/releases/latest/download/Slash-Command.dmg)。
2. 打开它,把 **Slash Command** 拖到 **Applications**(应用程序)上。
3. 从“应用程序”文件夹打开 Slash Command,菜单栏中会出现一个 `/` 键图标。
4. 通过该图标打开 **设置…**,使用顶部的 **权限** 区域。其中的按钮会替你打开系统设置里对应的面板。

使用 **Homebrew** 时,用下面的命令代替第 1、2 步:

```sh
brew install --cask yohangwak/tap/slash-command
```

这样安装时,命令行工具也会链接为 `slashcommand`。

第 4 步中的权限用途:

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
./scripts/build-app.sh --install   # builds, copies to ~/Applications, links ~/.local/bin/slashcommand if that folder exists
```

你需要 Swift 工具链(Xcode 或 Command Line Tools)。没有签名证书时,构建结果使用临时(ad-hoc)签名,每次重新构建后 macOS 都会再次请求权限。

</details>

### Windows

需要 x64 的 Windows 11。

1. 下载 [**Slash-Command-Windows-x64.zip**](https://github.com/yohangwak/slash-command/releases/latest/download/Slash-Command-Windows-x64.zip)。
2. 右键点击它,选择 **全部解压缩…**,解压到一个会长期保留的文件夹,例如 `%LOCALAPPDATA%\Programs`。
3. 打开解压出的 **Slash Command** 文件夹中的 **Slash Command.exe**。通知区域会出现一个 `/` 键图标,它可能藏在 **^** 箭头里。
4. 要在登录时启动,点击该图标并选择 **登录时打开**。

Windows 版目前还没有代码签名,第一次打开时 SmartScreen 可能会显示“Windows 已保护你的电脑”。请选择 **更多信息**,然后选择 **仍要运行**。每个版本都会在 `Slash-Command-Windows-x64.zip.sha256` 中列出 zip 的 SHA-256。

不需要任何权限。命令行工具 `slashcommand.exe` 位于同一文件夹。

## 使用

| 按键 | 效果 |
|---|---|
| `⇧⌥1` … `⇧⌥9` | 把最前面的智能体切换到对应预设的模型和 effort |
| `⇧⌥=` / `⇧⌥-` | 保持模型不变,把 effort 调高或调低一级 |

屏幕底部会弹出一个小提示,显示智能体的回应,例如 `Opus 5.5 · high`。快捷键只在受支持的终端位于最前面时才生效,因此在其他应用中,这些按键仍保持原有含义。你可以在设置中更改修饰键。

菜单栏图标会显示最前面会话中的智能体,以及每个预设对它会执行什么操作。

**在 Windows 上**,按键为 **Shift+Alt+1 … 9**、**Shift+Alt+=** 和 **Shift+Alt+-**,托盘图标的菜单中也会显示相同内容。在 Windows Terminal 中,Shift+Alt+= 和 Shift+Alt+- 也是它的“复制窗格”快捷键;当 Windows Terminal 位于最前面时,Slash Command 会占用它们。若想把它们留给 Windows Terminal,请在预设文件中设置 `"effortKeys": false` 或更改 `modifiers`。

## 预设

在 **设置… → 预设** 中编辑预设,也可以直接编辑 `~/.config/slashcommand/presets.json`。在 Windows 上,该文件为 `%USERPROFILE%\.config\slashcommand\presets.json`,可在托盘菜单中选择 **打开预设文件**。Windows 上目前还没有设置窗口。

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

应用自带一个命令行工具,使用相同的切换逻辑。用 Homebrew 安装时,可以直接用 `slashcommand` 调用。从磁盘映像安装时,它位于应用包内,需要创建一次链接:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf "/Applications/Slash Command.app/Contents/MacOS/slashcommand-cli" /usr/local/bin/slashcommand
```

在 Windows 上,`slashcommand.exe` 位于 `Slash Command.exe` 旁边。把该文件夹加入 `PATH` 后即可用 `slashcommand` 调用。

然后:

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

Windows:

| 终端 | 说明 |
|---|---|
| Windows Terminal | 无需设置。不支持从 Windows Terminal 外部移交过来的窗格(例如从开始菜单打开、由 Windows 交给 Windows Terminal 的 shell) |
| Orca | 无需设置 |
| WezTerm | 无需设置。不支持运行 WSL、tmux 或 SSH 的窗格。Grok、Cursor Agent、Antigravity 和 OpenCode 只有在关闭 `keepDefaults` 时才会在这里切换 |

在 Windows 上,不支持以管理员身份运行的窗口、WSL、tmux、Warp 和 VS Code 终端。

Slash Command 通过读取屏幕来操作每个智能体自带的模型选择器,因此依赖这些选择器显示的文字。当某个智能体修改了这些文字时,切换会停止,并且不再发送任何内容。如果你运行的版本尚未验证,`slashcommand doctor` 会告诉你。目前已验证的版本列在 [智能体](docs/agents.md#versions) 文档中。

## 隐私

Slash Command 不包含任何网络代码。它读取终端屏幕只是为了决定发送什么。它的日志(macOS 为 `~/Library/Logs/SlashCommand/slashcommand.log`,Windows 为 `%LOCALAPPDATA%\SlashCommand\Logs\slashcommand.log`)会记录你按下的键、结果和耗时,但从不记录屏幕上的内容。

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
