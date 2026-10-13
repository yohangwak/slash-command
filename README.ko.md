# Slash Command

**대화를 끊지 않고, 단축키 한 번으로 코딩 에이전트의 모델과 effort 를 바꿉니다.**

[English](README.md) · [日本語](README.ja.md) · [简体中文](README.zh-CN.md) · [Español](README.es.md)

Slash Command 는 macOS 메뉴 막대 앱입니다. 터미널에서 **⇧⌥1 … ⇧⌥9** 를 누르면 맨 앞 세션의 에이전트가 그 번호 프리셋의 **모델 + effort** 로 바뀝니다. **⇧⌥=** 와 **⇧⌥-** 는 effort 만 한 단계 올리고 내립니다.

**Claude Code, Codex, Grok, Cursor Agent, Antigravity, OpenCode** 를 **Ghostty, Orca, iTerm2, WezTerm, kitty** 에서 지원합니다.

- **키 한 번.** `/model` 을 치고, 행을 찾고, effort 를 맞추는 일을 대신합니다.
- **대화 도중에도 됩니다.** 쓰던 글은 입력창에 그대로 남습니다.
- **이 세션만 바꿉니다.** 새 세션의 기본값은 그대로입니다.
- **번호 하나로 모든 에이전트.** 1번이 Claude Code 에서는 Opus, Codex 에서는 GPT 모델일 수 있습니다. 앱이 맨 앞의 에이전트가 무엇인지 봅니다.
- **조심스럽게 설계했습니다.** 에이전트의 입력창이 보일 때만 키를 보내고, 확실하지 않으면 멈춥니다.

## 설치

macOS 13 이상이 필요합니다.

1. [최신 릴리스](https://github.com/yohangwak/slash-command/releases/latest)에서 `Slash-Command.zip` 을 내려받아 압축을 풀고 **Slash Command** 를 응용 프로그램 폴더로 옮깁니다.
2. 앱을 엽니다. 메뉴 막대에 `/` 키 모양 아이콘이 생깁니다.
3. 그 아이콘에서 **설정…** 을 열고 맨 위의 **권한** 칸을 씁니다. 버튼이 시스템 설정의 해당 화면을 바로 열어 줍니다.

| 권한 | 쓰는 곳 |
|---|---|
| **손쉬운 사용** (macOS 27 에서는 *기기 제어 및 데이터 접근* 목록) | Ghostty 화면 읽기, iTerm2 의 입력 방송(Broadcast Input)이 꺼져 있는지 확인 |
| **자동화** (Slash Command → Ghostty, Slash Command → iTerm2) | 터미널에 글자 넣기. 그 터미널에서 단축키를 처음 누를 때 macOS 가 묻습니다 |

WezTerm 과 kitty 는 둘 다 필요 없고, Orca 는 없어도 동작합니다. kitty 는 원격 제어를 켜야 합니다. 자세한 것은 [Terminals](docs/terminals.md)를 보세요.

로그인할 때 자동으로 띄우려면 설정의 **일반** 에서 **로그인할 때 실행** 을 켭니다.

<details>
<summary>소스에서 빌드하기</summary>

```sh
git clone https://github.com/yohangwak/slash-command.git
cd slash-command
./scripts/build-app.sh --install   # 빌드해서 ~/Applications 에 복사하고, ~/.local/bin 폴더가 있으면 slashcommand 링크를 겁니다
```

Swift 도구(Xcode 또는 Command Line Tools)가 필요합니다. 서명 인증서가 없으면 임시 서명이 되어, 다시 빌드할 때마다 macOS 가 권한을 다시 묻습니다.

</details>

## 쓰기

| 키 | 하는 일 |
|---|---|
| `⇧⌥1` … `⇧⌥9` | 맨 앞 에이전트를 그 프리셋의 모델과 effort 로 바꿉니다 |
| `⇧⌥=` / `⇧⌥-` | 모델은 그대로 두고 effort 를 한 단계 올리거나 내립니다 |

화면 아래에 에이전트가 답한 결과가 잠깐 뜹니다. 예: `Opus 5.5 · high`. 단축키는 지원하는 터미널이 맨 앞일 때만 잡으므로, 다른 앱에서는 같은 키가 원래대로 동작합니다. 조합 키는 설정에서 바꿀 수 있습니다.

메뉴 막대 아이콘을 누르면 맨 앞 세션의 에이전트와, 각 프리셋이 그 에이전트에 무엇을 하는지 보입니다.

## 프리셋

**설정… → 프리셋** 에서 편집하거나 `~/.config/slashcommand/presets.json` 을 직접 고칩니다.

```json
{
  "version": 1,
  "slots": [
    { "claude": { "model": "opus",   "effort": "high" }, "codex": { "model": "gpt-6-astra", "effort": "high" } },
    { "claude": { "model": "sonnet", "effort": "high" }, "codex": { "model": "gpt-6.1-sol", "effort": "high" } },
    { "name": "밤샘", "claude": { "model": "fable", "effort": "max" } }
  ]
}
```

프리셋 번호는 «의도» 입니다. 프리셋마다 에이전트별 설정을 하나씩 두고, 단축키는 맨 앞 에이전트의 설정을 씁니다. 그 에이전트의 설정이 없는 프리셋은 거기서 아무것도 하지 않습니다. 모든 키는 [Presets](docs/presets.md)에 있습니다.

## 명령줄

앱에는 같은 전환 로직을 쓰는 명령줄 도구가 들어 있습니다. 앱 묶음 안에 있으므로, `slashcommand` 로 부르려면 한 번 링크를 겁니다.

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf "/Applications/Slash Command.app/Contents/MacOS/slashcommand-cli" /usr/local/bin/slashcommand
```

그다음:

```sh
slashcommand list              # 프리셋 목록
slashcommand where             # 맨 앞 터미널과 그 에이전트
slashcommand doctor --screen   # 대상·화면 읽기·입력창 점검. 아무것도 보내지 않습니다
slashcommand apply 2 --trace   # 프리셋 2 를 적용하고 단계별 시간을 찍습니다
slashcommand run 2 claude      # 프리셋 2 로 새 세션을 엽니다
```

## 지원 범위

| 터미널 | 참고 |
|---|---|
| Ghostty | 손쉬운 사용과 자동화가 필요합니다. Ghostty 안의 tmux 는 아직 지원하지 않습니다 |
| Orca | 설정할 것 없음. 손쉬운 사용은 선택이며, 켜면 탭을 옮긴 직후에도 바로 따라갑니다 |
| iTerm2 | 자동화가 필요하고, 입력 방송 확인에 손쉬운 사용이 필요합니다 |
| WezTerm | 설정할 것 없음 |
| kitty | 먼저 원격 제어를 켭니다 |
| tmux | Orca, iTerm2, WezTerm, kitty 안에서 |

Terminal.app 과 VS Code 터미널은 지원하지 않습니다.

| 에이전트 | 확인한 버전 |
|---|---|
| Claude Code | 2.1.283 – 2.1.296 |
| Codex | 0.156.0 – 0.162.0 |
| Grok | 1.0.46, 1.0.50 |
| Cursor Agent | 2026.10.01 |
| Antigravity | 1.3.1, 1.3.3 |
| OpenCode | 1.18.35, 2.0.25 |

Slash Command 는 화면을 읽으며 각 에이전트의 모델 선택창을 조작하므로, 그 선택창에 보이는 글에 기댑니다. 에이전트가 그 글을 바꾸면 전환은 멈추고 더는 아무것도 보내지 않습니다. 쓰는 버전이 확인되지 않은 것이면 `slashcommand doctor` 가 알려 줍니다.

## 개인정보

Slash Command 에는 네트워크 코드가 없습니다. 터미널 화면은 무엇을 보낼지 정할 때만 읽습니다. 기록 파일(`~/Library/Logs/SlashCommand/slashcommand.log`)에는 누른 키, 결과, 걸린 시간이 남습니다. 화면에 있던 글은 남기지 않습니다.

## 문서

아래 문서는 영어로만 있습니다.

- [Presets](docs/presets.md): 프리셋 파일, `run` 으로 새 세션 열기
- [Terminals](docs/terminals.md): 터미널별 설정과 한계, tmux
- [Agents](docs/agents.md): 에이전트마다 어떻게 바꾸는지, 기본값은 어떻게 되는지
- [How it works](docs/how-it-works.md): 대상 찾기, 선택창, 확인 창, 걸리는 시간
- [Safety and limits](docs/safety.md): 키를 보내기 전에 앱이 지키는 규칙
- [Development](docs/development.md): 빌드, 테스트, 언어 추가

## 언어

앱은 시스템 언어를 따릅니다. 영어, 한국어, 일본어, 중국어(간체), 스페인어, 프랑스어, 독일어, 포르투갈어, 아랍어가 들어 있습니다. 영어와 한국어 말고는 기계 번역이며, 고쳐 주시면 반영합니다.

## 기여

버그 제보, 새 에이전트 버전에 맞춘 수정, 번역 교정을 환영합니다. [CONTRIBUTING.md](CONTRIBUTING.md)를 보세요.

## 라이선스

[MIT](LICENSE)

Slash Command 는 독립 프로젝트입니다. Anthropic, OpenAI, xAI, Cursor, Google, OpenCode, 그리고 지원하는 터미널의 제작사와 관계가 없습니다. 제품 이름은 호환성을 설명하는 데에만 썼습니다.
