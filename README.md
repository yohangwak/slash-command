# Slash Command

Ghostty·Orca 터미널에서 **⇧⌥1 … ⇧⌥9** 를 누르면, 맨 앞 세션이 어느 에이전트인지에 맞춰
그 번호 프리셋의 **모델 + effort** 로 바꾸는 맥 메뉴 막대 앱. 지원하는 에이전트: **claude · codex · grok · cursor-agent · antigravity(agy) · opencode**. **⇧⌥=** · **⇧⌥-** 는 모델은 그대로 두고 effort 만 한 단계 올리고 내린다.

`/model`·`/effort` 를 매번 치는 대신 단축키 한 번. 대화 도중에도 되고, 쓰던 글은 그대로 남고, 새 세션 기본값은 바뀌지 않는다.

지금 하는 일은 모델·effort 전환 하나다. 이름이 Slash Command 인 것은 에이전트의 슬래시 명령을 단축키로 보내는 앱으로 넓혀 갈 자리를 둔 것이다(2026-10-10 개명 — 그 전 이름은 ModelSwitch, 그 전은 Gear).

## 쓰기

| 무엇 | 어떻게 |
|---|---|
| 전환 | Ghostty·Orca 가 맨 앞일 때 `⇧⌥번호`(조합 키는 편집 화면에서 바꾼다). 화면 아래에 «에이전트가 알려 준» 결과가 잠깐 뜬다(`Opus 5.5 · high`) |
| effort 만 | `⇧⌥=` 올림 · `⇧⌥-` 내림. 끝 단계에서는 바꾸지 않고 그렇게 알린다 |
| 메뉴 | 메뉴 막대 아이콘. 맨 위에 «지금 맨 앞 세션의 에이전트»(`Claude Code · Orca`)가 뜨고, 프리셋 줄은 그 에이전트에 «지금 누르면 되는 값»(`opus · high`)만 보여 준다. 그 에이전트의 설정이 없는 번호는 흐리게 나온다. 권한·단축키에 문제가 있을 때만 그 줄이 생긴다 |
| 프리셋 편집 | 메뉴 막대 아이콘 → 「설정…」(Settings…). 프리셋은 접혀 있고, 펼치면 에이전트별 모델·effort — 쓰는 에이전트만 「에이전트 추가」로 넣는다. 저장하지 않은 편집은 창을 닫았다 열어도 남는다(파일은 `~/.config/slashcommand/presets.json`) |
| 새 세션 | `slashcommand run 2 claude` — 그 프리셋으로 새 세션을 연다(`claude --model … --effort …`). cursor·antigravity·opencode 는 `--model` 이 화면 이름이 아니라 id 를 받아서, 그 CLI 의 모델 목록(`cursor-agent models` · `agy models` · `opencode models --verbose`)에서 id 를 찾아 넘긴다(목록을 못 받거나 이름이 없으면 열지 않는다). cursor 는 그렇게 연 모델을 새 세션 기본값으로도 저장하므로, 연 뒤 1분 동안 기본값이 «연 모델» 로 바뀌면 연 전 값으로 되돌린다(`keepDefaults`. 그 사이 다른 세션이 다른 모델로 바꾼 것은 건드리지 않고, 겹쳐 연 세션들은 첫 열기 전의 값을 같이 기준으로 쓴다). opencode 는 variant 를 여는 옵션이 없어 모델만 맞추고, 2.x 는 여는 옵션에 `--model` 자체가 없어 열지 않고 알린다 |
| 터미널에서 | `slashcommand list` · `where` · `doctor --screen`(대상·에이전트 판·화면 읽기·입력창 점검, 아무것도 보내지 않음) · `apply 2 [--trace]` · `effort up` · `plan 1 codex` |
| 기록 | `~/Library/Logs/SlashCommand/slashcommand.log` (누른 것, 결과, 단계별 걸린 시간) |

번호는 「의도」다 — 같은 번호가 claude 에서는 claude 모델, codex 에서는 codex 모델로 간다.
한쪽 설정이 없는 번호는 그 에이전트에서 아무것도 하지 않는다.

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
    { "name": "밤샘", "claude": { "model": "fable", "effort": "max" } }
  ]
}
```

- claude `model`: 별칭(`fable`·`opus`·`sonnet`·`haiku` — 그 계열의 최신), 선택창에 보이는 이름(`Opus 5`), 또는 전체 모델 id(`claude-opus-5`). `effort`: `low`·`medium`·`high`·`xhigh`·`max`.
- codex `model`: `/model` 선택창에 보이는 모델의 slug. `effort`: `low`·`medium`·`high`·`xhigh`·`max`·`ultra`(모델이 지원하는 것).
- `name` 은 붙이고 싶을 때만. 없으면 모델·effort 로 보여 준다.
- `keepDefaults`(기본 켬): 이 세션만 바꾼다. 끄면 claude 는 새 세션 기본값까지 바꾼다.
- `acceptSwitchPrompt`(기본 켬): 아래 「claude 의 확인 창」.

## 지원하는 에이전트

번호는 «의도» 라서 한 프리셋에 에이전트마다의 설정을 함께 둔다(`"claude": {…}, "grok": {…}` …). 맨 앞 세션의 에이전트에 해당하는 설정만 쓰고, 없으면 아무것도 하지 않는다.
모델 칸은 에이전트가 화면에 보여 주는 이름이다(대소문자·기호는 무시: `claude-opus-5-5` = `Claude Opus 5.5`).

| 에이전트 | 어떻게 바꾸나 | 기본값(새 세션) | 걸리는 시간 |
|---|---|---|---|
| claude | `/model` 선택창에서 모델·effort 를 맞추고 `s`(이 세션만) | 건드리지 않음 | Orca 0.1~0.35초 |
| codex | `/model` 선택창, `s`(이 세션만) | 건드리지 않음 | Orca 0.15~0.3초 |
| grok | `/model <모델> <effort>` 한 줄 | `~/.grok/config.toml` 의 `[models]` 두 키를 저장함 → 끝나고 되돌림 | 약 0.35초 |
| cursor-agent | `/model` 목록에서 글자를 한 글자씩 쳐 걸러 고르고, Tab 으로 매개변수(Effort)를 맞춰 확정 | `cli-config.json` 의 모델 관련 네 키를 저장함 → 되돌림 | 약 0.7~1.3초 |
| antigravity(agy) | `/model` 선택창의 커서와 Effort 슬라이더(←/→) | `settings.json` 의 `model` 을 저장함 → 되돌림 | 약 0.5초 |
| opencode | `/models` 대화상자에서 «이름 + 제공자» 로 걸러 고르고 `/variants` 로 variant 를 맞춤 | `model.json` 의 `recent`·`variant` 를 저장함 → 되돌림 | 약 0.4~0.7초 |

- claude·codex 외의 네 에이전트에는 「이 세션만」 확정이 없어서 새 세션 기본값까지 저장된다(2026-10-07 실측). 그래서 «전환 뒤 그 키들만 전환 전 값으로 되돌린다» — 다른 키나 다른 세션이 쓴 값은 건드리지 않고, 되돌려도 돌고 있는 세션은 모델을 유지한다(cursor 로 확인). `keepDefaults` 를 끄면 되돌리지 않는다.
- 전환 전에 기본값 파일이 «없었으면»(그 에이전트를 처음 쓰는 경우) 전환 뒤 그 키들을 다시 없앤다. 파일이 있는데 «읽지 못하면» 되돌릴 값을 모르므로 아무것도 보내지 않고 멈춘다. opencode 의 파일 위치는 Slash Command 가 아니라 «그 세션의» `XDG_STATE_HOME` 을 따른다(세션마다 다르고 어느 쪽인지 좁힐 수 없으면 멈춘다).
- 모두 «입력창이 비어 있고 작업 중이 아닐 때만» 보낸다. 작업 중 표시: grok 안내 줄의 `Ctrl+c:cancel`, cursor 입력줄 위의 스피너, agy 안내 줄의 `esc to cancel`, opencode 상자 아래의 `esc interrupt`. 쓰던 글이 있으면 보내지 않는다.
- 명령을 친 뒤 «그 글이 입력창에 보이는지» 확인하고서야 Enter 를 보낸다. opencode 는 긴 답변이 끝난 뒤 입력창이 글자를 받지 않는 상태가 있는데(Ctrl+P → Esc 로 풀린다), 이때도 글이 안 보이면 아무것도 보내지 않고 멈춘다.
- 시험한 판: grok 1.0.46 · cursor-agent 2026.10.01(14929f9 · e373342) · agy 1.3.1·1.3.3 · opencode 1.18.35. 다른 판이면 `doctor` 가 알려 준다. **opencode 2.x 는 아직 안 된다**(2.0.25 실측: 모델 대화상자가 제공자 이름으로 걸러지지 않고 행에 제공자 칸이 없다 — 멈출 뿐 엉뚱한 것을 고르지는 않는다).
- cursor 를 `--yolo` 로 열면 모델 줄 오른쪽에 `Run Everything` 이 붙는다 — 모델 줄은 그 앞까지만 읽는다. effort 만 바꿀 때는 목록의 커서가 «지금 모델» 행에 놓인 것을 보고 나서 Tab 을 누른다(목록이 막 열린 순간에는 맨 윗줄에 있기도 하다).

## 설치

```sh
./scripts/build-app.sh --install   # ~/Applications/Slash Command.app 에 설치하고 실행, ~/.local/bin/slashcommand 링크
~/Applications/Slash\ Command.app/Contents/MacOS/SlashCommand --login-item on   # 로그인할 때 실행(설정 창의 「일반」에서도 켠다)
```

ModelSwitch 로 깔려 있던 맥에서는 `--install` 이 옛 앱(`~/Applications/ModelSwitch.app`)의 로그인 항목을 끄고 앱과 `modelswitch` 링크를 지운 뒤 새로 깐다(옛 로그인 항목이 켜져 있지 않았으면 해제를 확인할 수 없다고 알린다 — 승인 대기로 남은 항목은 시스템 설정의 로그인 항목에서 지운다). 프리셋은 새 앱이 처음 뜰 때 `~/.config/modelswitch/presets.json` 에서 복사해 온다(옛 파일은 남는다). 번들 id 가 바뀌었으므로(`com.yohangwak.slashcommand`) 아래 권한은 새 앱에서 다시 허용해야 한다.

처음 한 번 허용할 것 — **앱이 그 설정 화면을 바로 열어 준다**(설정 창 맨 위 「권한」 칸의 「설정 열기…」 버튼. 권한이 꺼져 있으면 메뉴에도 「손쉬운 사용 켜기…」 줄이 생기고, 권한이 필요한 터미널에서 단축키를 눌러도 열린다):

- **손쉬운 사용 / Accessibility**(Slash Command): Ghostty 화면 읽기에 꼭 필요하다. Orca 는 없어도 되지만 켜 두면 탭을 옮긴 직후에도 지금 보이는 탭을 정확히 안다(없으면 1~2.5초 동안 옮기기 전 터미널로 갈 수 있다).
- **자동화 / Automation**(Slash Command → Ghostty): 터미널에 글자를 넣는 데 쓴다. 처음 단축키를 누를 때 시스템이 묻는다.

시스템 설정에는 «Accessibility» 가 두 곳이다 — 사이드바의 것은 장애 접근성 기능 화면이고, 필요한 것은 Privacy & Security 안의 앱 권한 목록이다. 그래서 말로 안내하지 않고 버튼으로 연다. 「권한」 칸은 상태(켜짐/꺼짐)를 1초마다 다시 읽어, 설정에서 켜고 돌아오면 바로 ✓ 로 바뀐다. `open -a "Slash Command" --args --settings` 로 그 창을 띄운 채 시작할 수 있다.

## 언어

화면의 문구는 영어가 기준이고, 번역이 있는 언어는 **시스템의 언어 순서를 따라 자동으로** 고른다(시스템 설정 → 일반 → 언어 및 지역. 같은 화면의 「응용 프로그램」에서 이 앱만 다른 언어로 정할 수도 있다). 번역이 없는 언어·문장은 영어로 나온다.

- **들어 있는 언어 9개**: 영어(기준) · 한국어 · 일본어 · 중국어(간체) · 스페인어 · 프랑스어 · 독일어 · 포르투갈어 · 아랍어(오른쪽에서 왼쪽으로 배치된다). 한국어 말고는 기계 번역이고 원어민이 검수하지 않았다 — 어색한 문장은 그 언어의 `Localizable.strings` 한 줄을 고치면 된다. 언어를 더하려면 `Resources/<언어>.lproj/` 에 `Localizable.strings` 와 `InfoPlist.strings`(자동화 권한을 물을 때의 설명)를 넣는다.
- 코드에 쓴 영어 문장이 곧 키다(`loc("Quit Slash Command")`). 번역은 `Resources/<언어>.lproj/Localizable.strings` 에 있고 `build-app.sh` 가 앱 묶음에 넣는다. 맥이 번역해 주는 것이 아니라 «우리가 넣어 둔 언어 가운데» 고르는 것이다.
- 값이 들어갈 자리는 `%@`(차례대로)와 `%1$@`(번호로 — 어순이 다른 언어에서)만 쓴다.
- 테스트가 언어마다 «코드의 문장과 번역이 빠짐없이 맞는지, 자리표가 같은지» 를 본다 — 문장을 바꾸거나 더하면 번역을 고칠 때까지 테스트가 실패한다.
- 에이전트 화면의 문구(`Select model` 등)와 제품 이름(Claude Code · Codex …)은 번역하지 않는다.
- 번역되는 것: 메뉴·설정 창·알림과 전환 결과·오류 문장. 명령줄 도구(`slashcommand doctor`·`plan` …)의 자체 출력과 기록 파일의 표지는 영어 고정이다 — 진단용이라 언어마다 달라지면 읽기 어렵다(그 안에 섞이는 전환 결과·오류 문장은 시스템 언어를 따른다).
- 기존 테스트들은 한국어 번역표를 켜고 돈다(`KoreanMessagesTestCase`) — 그 테스트들이 보는 한국어 문장은 «영어 문장 → 번역 → 값 넣기» 를 다 거친 것이다.

## 어떻게 동작하나

1. **단축키** — Carbon 전역 핫키. 키 위치로 잡으므로 한글 입력 상태와 무관하다. Ghostty·Orca 가 맨 앞일 때만 등록해서 다른 앱에서는 그 조합이 원래대로 동작한다.
2. **대상 찾기**
   - Ghostty: AppleScript 로 맨 앞 터미널의 id·제목·폴더를 읽는다. 제목에 `claude`/`codex` 가 없으면 그 폴더에서 도는 에이전트 프로세스로 가린다.
   - Orca: 화면에 떠 있는 워크스페이스는 Orca 상태 DB(`profile-state.db` 의 `workspaceSession`)에서, 그 안의 활성 탭·터미널은 터미널 목록에서 읽는다. 에이전트 종류는 그 터미널에서 도는 프로세스로 가린다(목록의 `agentIdentity` 는 대기 중에 비어 온다).
3. **입력창 확인** — 화면을 읽어 에이전트의 입력창이 «보일 때만» 보낸다(아래 「안전」).
4. **전환** — 두 에이전트 모두 `/model` 선택창을 화면으로 읽으며 조작한다: 커서가 어느 행에 있는지 읽고, 그만큼만 움직이고, 도착한 것을 다시 읽어 확인한 뒤 **「이 세션만」(`s`)으로 확정**한다.
   - claude: 모델 행으로 커서를 옮기고, effort 줄(`● High effort ←/→`)을 목표 단계로 맞춘다. 결과 줄(`Set model to Opus 5.5 for this session only with high effort`)이 알림에 뜬다.
   - codex: 모델은 숫자 키, effort 는 커서로 고른다(effort 를 숫자 키로 고르면 기본값까지 저장된다). `max`·`ultra` 는 「More reasoning…」 아래에서 찾는다.
   - 쓰던 글: claude 는 `Ctrl+S` 로 보관했다 claude 가 되돌리고, codex 는 kill 버퍼로 옮겼다 되돌린다(한 줄일 때만).

글자·키는 합성 키 입력이 아니라 터미널에 바이트로 직접 쓴다(Ghostty `perform action "text:…"`, Orca 는 앱의 런타임 소켓 — 안 되면 `orca terminal send`).

### claude 의 확인 창

claude 는 방금 응답한 대화에서 모델이나 effort 를 바꾸면 `Switch model?` · `Change effort level?` 을 띄운다(대화 기록을 다시 읽는다는 안내).
기본은 **받아들인다** — 단, 그 창이 «우리가 고른 그 값»(모델 이름이나 effort 단계)을 묻고 커서가 Yes 에 있을 때만 Enter 를 보낸다. 다른 창에는 아무것도 보내지 않는다.
`acceptSwitchPrompt` 를 끄면 그 창에 아무것도 보내지 않는다 — 알림이 「Enter 로 확정해 주세요」라고 알리고, 고를 때까지(20초) 기다렸다가 결과를 알린다.

### 선택창을 못 쓰는 경우

- claude 선택창에 그 모델 행이 없으면(오래된 모델, 맞춤 id) 선택창을 닫고 `/model X`·`/effort Y` 명령으로 한다. 이 명령은 새 세션 기본값(`~/.claude/settings.json`)까지 바꾸므로, 전환 전 내용을 잡아 뒀다가 기본값 항목만 되돌린다.
- **Ghostty 의 claude** 는 항상 이 명령 방식이다. Ghostty 는 접근성으로 내주는 화면 글자를 0.5초 동안 그대로 다시 주기 때문에 선택창을 단계마다 확인하면 2.4~3.8초가 걸린다. 그래서 화면 대신 「claude 가 기본값 파일을 다시 썼다」를 명령이 실행된 신호로 쓴다. 파일을 다시 쓰지 않는 명령(`/effort max` 는 이 세션에만 적용된다)은 0.5초 뒤의 새 화면에서 결과 줄을 확인한다.
- Ghostty 에서 제목에 `claude`/`codex` 가 없고 같은 폴더에서 둘이 같이 돌면, 그 터미널 화면에 어느 쪽 입력창이 보이는지로 가린다.

## 걸리는 시간

집 맥(2026-10-06 05:35~06:55, claude 2.1.289 · codex 0.160.0/0.160.1)과 맥북(07:00~07:25, claude 2.1.283 · codex 0.156.0)에서 잰 값. Orca 1.4.220 · Ghostty 1.3.1.

| | 처음(2026-10-05) | 지금 |
|---|---|---|
| Orca · claude | 6.4초 | 0.08~0.35초 (실제 단축키 → 앱: 0.18~0.25초) |
| Orca · codex | 2.65초 | 0.15~0.30초 |
| Orca · effort 한 단계 | — | 0.1~0.4초 |
| Orca · 맨 앞 터미널 찾기 | 0.45초 | 0.07~0.10초 |
| Ghostty · claude | 미측정 | 알림까지 약 0.6초 (실제 단축키 → 앱, 맥북) |
| Ghostty · claude effort 한 단계 | — | 1.8~2.5초 (선택창 방식이라 단계마다 0.5초) |
| Ghostty · codex | 미측정 | 3.0~4.6초 (단계마다 화면이 0.5초 늦게 따라온다) |

줄인 것: 고정 대기(4.9초)를 화면 확인으로 교체 · `orca` 명령 실행(회당 0.2초)을 앱 소켓 직접 호출(1ms 안쪽)로 · `ps` 실행(0.2초)을 프로세스 안 조회로 · `osascript` 실행(0.2~0.3초)을 프로세스 안 AppleScript 로.
`slashcommand apply <번호> --trace` 가 단계별 시간을 찍는다.

## 안전

- **입력창이 안 보이면 아무것도 보내지 않는다.** 권한 확인 창·승인 창·선택창이 떠 있을 때 Enter 를 보내면 그 창의 기본 선택지가 눌린다. 판정은 「창이 없다」가 아니라 「입력창이 보인다」다(`Readiness.swift`, 실제 화면 표본으로 테스트).
- **화면을 못 읽으면 보내지 않는다.** 확인 없이 보내는 경로는 없다.
- **낡은 화면으로 판단하지 않는다.** Ghostty 의 첫 판단은 0.5초 보관이 지난 새 화면으로만 한다. (2026-10-06: 시험 중 낡은 화면을 믿고 열려 있는 claude 선택창에 Enter 를 보내, 커서 행이 새 세션 기본 모델로 저장됐다.)
- **읽는 터미널과 쓰는 터미널이 같아야 한다.** Ghostty 는 읽기·쓰기 모두 대상이 지금도 포커스 터미널일 때만 한다.
- **Esc 는 우리가 연 선택창이 보이는 동안에만 누른다.** 작업 중인 에이전트에 Esc 는 작업 중단이다.
- **선택창·입력창은 화면 «맨 아래»에 있는 것만 인정한다.** 선택창은 맨 아랫줄이 선택창의 안내(`s to use this session only`, `esc back`)일 때만, 거기서 위로 올라가며 행과 머리말(`Select model`, `Select Reasoning Level` …)을 찾는다. 대화 내용에 선택창처럼 보이는 글이 있어도 읽지 않는다(2026-10-06: 실제 화면에서 그 글의 행을 읽는 것을 확인하고 고쳤다). 승인 창도 번호 행을 쓰지만 안내 문구가 다르다.
- 좁은 창에서 행의 설명이 다음 줄로 접혀도 읽는다(62칸·58칸에서 확인).
- **성공의 증거는 화면에 보이는 «우리 명령의 답»이다.** claude 의 기본값 파일은 다른 세션도 쓰므로, 그 파일이 바뀐 것만으로는 성공으로 치지 않는다.
- effort 한 단계는 끝 단계에서 누르지 않는다(claude 선택창은 끝에서 반대쪽 끝으로 돈다). claude 는 커서가 「지금 쓰는 모델」(`✔`) 행에 있을 때만 확정한다.
- 알림에 쓰는 결과 문구는 마지막으로 친 명령 바로 아래의 답(작업 중이면 입력창 위의 알림 줄)에서 읽는다. 예전 전환의 줄이 화면에 남아 있어도 읽지 않는다.
- 화면 글자는 기록 파일에 남기지 않는다(프롬프트·코드·비밀이 섞여 있다).

## 한계

- codex 선택창의 모델 순서는 `~/.codex/models_cache.json` 에서 계산한다. 10번째 이후 모델은 숫자 키로 고를 수 없다.
- claude 선택창에서 접혀 보이지 않는 모델(`… +2 models`, 낮은 창에서는 커서 행 하나만 보인다)은 커서를 맨 위로 올린 뒤 한 칸씩 내려가며 찾는다(90×14 에서 2~3.5초). 그래도 못 찾을 때만 명령 방식으로 간다(기본값을 바꿨다 되돌린다).
- Orca 의 「화면에 떠 있는 워크스페이스」는 공개 인터페이스가 아닌 상태 DB 에서 읽는다. 형식이 바뀌면 추측하지 않고 실패한다.
- **Orca 에서 탭을 옮긴 직후:** 상태 DB 와 `terminal.list` 의 «활성 탭» 은 UI 보다 1.3~2.5초 늦다. 그래서 «손쉬운 사용» 권한이 있으면 Orca 의 탭 줄(접근성 트리, 활성 탭만 `text-foreground` 클래스)을 읽어 터미널 목록의 탭 제목 순서와 맞춘다 — 2026-10-07 같은 전환 7회에서 0.3초 뒤 7/7 맞음(DB 방식은 0/7). 권한이 없거나 탭 줄에 터미널이 아닌 탭이 섞여 맞지 않으면 옛 DB 방식으로 되돌아가고(지연 위험 그대로), 탭 제목 순서가 똑같은 워크스페이스가 둘이면 (늦은 DB 로 고르지 않고) 보내지 않는다. 분할 창의 활성 분할은 아직 목록 값을 쓴다.
- Orca 앱 소켓도 공개 인터페이스가 아니다(`orca` 명령이 쓰는 통로). 못 쓰면 `orca` 명령으로 되돌아간다(회당 0.2초).
- Ghostty 의 codex 는 3~4.6초 걸린다. Ghostty 가 화면 글자를 0.5초씩 보관하는 한 줄일 방법을 찾지 못했다(다른 접근성 속성도 같은 보관본을 준다).
- 명령 방식에서 claude 는 effort 가 없는 모델(Haiku)에도 「Set effort level to high」라고 답한다 — 알림은 claude 가 한 말을 그대로 옮긴다.
- 단축키로 되는 터미널은 Ghostty 와 Orca 다. tmux · kitty · WezTerm 은 시험 단계 — 대상을 직접 지정한 명령줄로만 된다(`slashcommand apply 2 --tmux <pane> --agent claude`, `--kitty <창 id> --kitty-socket unix:/경로`, `--wezterm <pane id>`). 2026-10-07 맥북에서 실제 전환을 확인했다(1~2초). iTerm2 는 맥북에서 전환까지 확인했지만(약 1초) 입력 방송(Broadcast Input)이 켜져 있으면 다른 칸에도 입력이 들어가는 문제를 구조적으로 막지 못해 아직 넣지 않았다(별도 작업). Terminal.app · Orca 플로팅 터미널은 지원하지 않는다.
- 새 에이전트들의 한계: cursor 의 매개변수 편집에서 Effort 말고 Context·Fast 는 건드리지 않는다 · cursor 는 목록이 10줄씩 보이므로 이름을 걸러서 찾는다(이름이 둘 이상 겹치면 정확히 같은 이름만 고른다) · agy 는 긴 출력 뒤에 입력창이 다시 그려지지 않을 때가 있어(Ctrl+L 로 풀린다) 그때는 «입력창이 보이지 않는다» 로 멈춘다 · opencode 의 목록 커서는 글자로 보이지 않아 «걸러낸 맨 위 행이 우리가 찾는 그 행일 때만» 고른다. 그래서 즐겨찾기한 비슷한 이름의 모델이 위에 오면(`GLM-5.3` 을 찾는데 `GLM-5.3-Flash` 가 맨 위) 고르지 않고 멈춘다(2026-10-08 실측).
- 화면 문구(영어)에 기대므로 claude·codex 가 선택창의 글을 바꾸면 멈춘다 — 멈출 뿐 엉뚱한 키를 보내지는 않는다. 확인한 판(claude 2.1.283·2.1.288·2.1.289·2.1.291·2.1.292·2.1.296, codex 0.156.0·0.160.0·0.160.1·0.162.0)과 다른 판이면 `doctor` 가 «확인 못 한 판» 이라고 알려 준다. 계약 전문: `docs/CONTRACT.md`.

## 개발

```sh
swift build && swift test                  # 핵심 로직은 SlashCommandCore, 화면 표본은 Tests/…/Fixtures, 선택창 흉내는 테스트 안의 FakeClaude·FakePicker
.build/debug/slashcommand plan 1 codex      # 보낼 단계만 출력
.build/debug/slashcommand apply 2 --orca <핸들> --agent claude --trace   # 대상을 직접 지정(시험용)
SLASHCOMMAND_SCREEN_LAG_MS=520 .build/debug/slashcommand apply 1 --orca <핸들> --agent claude   # Ghostty 용 경로를 Orca 세션에서
SLASHCOMMAND_CONFIG=/path/presets.json …    # 다른 프리셋 파일
```

시험할 때: 대상을 직접 지정한 시험은 감지 경로를 안 탄다(`where`·`doctor` 로 따로 본다) · 명령 방식 시험은 «지금 기본값과 같은 값»으로만 하고 끝나면 `shasum ~/.claude/settings.json` 을 처음과 대조한다 · 시험 세션에 글자를 보내기 전에 화면을 먼저 읽는다.

화면을 눈으로 확인할 때(화면 녹화 권한 없이): `SlashCommandApp --snapshot 파일.png [--dark] [--collapsed] [--height N]` 이 설정 창을 그림으로 내고, `--menu-text [번들 id]` 가 메뉴의 줄들을 글로 찍는다(그 앱이 맨 앞인 것으로 친다. 아무것도 보내지 않는다). 다른 언어로 보려면 `SLASHCOMMAND_L10N_DIR=$PWD/Resources SLASHCOMMAND_LANG=ko` 를 앞에 붙인다.

구조: `SlashCommandCore`(프리셋·감지·입력·화면 판정·단계 실행·기본값 복원) · `slashcommand`(명령줄) · `SlashCommandApp`(메뉴 막대·단축키·알림·편집 화면).

아이콘은 «키 하나에 슬래시» 다. 앱 아이콘은 `swift scripts/make-icon.swift` 로 `scripts/AppIcon.icns` 를 다시 만들고(`--preview 파일.png [크기]` 로 한 장만 볼 수 있다), 메뉴 막대 아이콘은 `StatusIcon.swift` 가 같은 그림을 템플릿 이미지로 그린다.
