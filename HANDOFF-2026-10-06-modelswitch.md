# 인계 — ModelSwitch (2026-10-06 05:40 KST)

이전 대화: Orca 워크스페이스 `ai-assistant/model-picker` 의 claude 세션(이제 수정 중단, 읽기 전용).
이 대화(`modelswitch/initial`)가 **유일한 수정 담당**이다.

## 임무

맥 메뉴 막대 앱 **ModelSwitch**(작업명 Gear 에서 개명)를 이 repo 에서 이어 만든다.
터미널에서 단축키(기본 `⇧⌥번호`)를 누르면, 맨 앞 세션이 claude 인지 codex 인지에 맞춰 그 번호 프리셋의
**모델 + effort** 로 바꾼다. 요한님이 `/model`·`/effort` 를 대화 도중 자주 바꾸는데 매번 치는 게 불편해서 시작했다.

시제품은 동작한다(집 맥에 설치돼 있고 요한님이 실제로 눌러 전환됨). 남은 일은
① 이 repo 로 옮기고 개명 ② **속도**(지금 한 번에 약 7초 — 요한님: «바로 됐으면 좋겠는데») ③ 개선 묶음
④ 다른 사람도 쓸 수 있게 일반화(터미널·에이전트 확장, 9개 언어, 배포).

## 요한님 결정 (2026-10-06, 이 대화에서 자유 발화로)

| 무엇 | 결정 |
|---|---|
| 이름 | **ModelSwitch** |
| 기본 단축키 | `⇧⌥` + 1~5 (구현됨 — 프리셋 개수만큼, 최대 9. 조합 키는 편집 화면에서 변경) |
| 프리셋 | 1 = opus / gpt-6-astra · 2 = sonnet / sol · 3 = fable (codex 없음), 전부 high (구현됨. 「sol」은 `gpt-6.1-sol` 로 넣었고 **요한님 확인 안 받음**) |
| effort 만 올리고 내리는 단축키 | «codex 는 전용 단축키가 있는 것 같은데 claude 는 없나? 없으면 해야지» |
| 속도 | «속도 신경써줘 … 바로 됐으면 좋겠는데» |
| 그 밖의 내 권장안 | «나머지는 너가 권장하는대로 모두 진행해줘» — 아래 「다음 단계」의 권장안 전부 |
| 코드 위치 | 이 repo(`yohangwak/modelswitch`) — 요한님이 직접 만들고 워크스페이스를 열었다 |

## 경계

| 하는 것 | 안 하는 것 | 🔴 요한님 승인 필요 |
|---|---|---|
| 이 repo 안의 코드·테스트·커밋·PR·머지 | `ai-assistant/model-picker` 워크스페이스 수정(원본 `apps/gear/` 는 읽기만) | repo 공개 전환, 외부 배포(공증 배포본 공개·Homebrew 등록·웹 게시) |
| 집 맥의 앱 재설치·개명 이전 | 요한님의 실제 세션에 시험 입력 보내기 | 사 맥·맥북 설치(요한님이 «설치하겠습니다»에 답하지 않았다) |
| 시험용 세션을 **이 워크스페이스에** 띄워 시험 | 새 워크스페이스·repo 밖 워크트리 생성 | 프리셋 「sol」 해석 확인 |

- 이 repo 에 `.github/`(Pullfrog, 커밋 `6a7add8`)가 있다. 건드리기 전에 읽을 것.
- 비서 기록은 `python3 ~/Repos/yohangwak/ai-assistant/bin/brain-note.py save <경로>=<파일> -m "…"`. 이전 대화의 일지는 `log/2026-10-05-2305-gear-model-picker-k7m2.md`(main `1fcdb08`·`ecb9c7d`) — 실측 시각·경위가 거기 있다. 이어 쓰지 말고 새 일지 파일을 만든다.

## ✅ 끝난 것

- **코드**: `/Users/yohan/orca/workspaces/ai-assistant/model-picker/apps/gear/` — **미커밋·untracked**(어느 repo 에도 없다. 유일본).
  SwiftPM 패키지: `GearCore`(프리셋·감지·입력·판정·기본값 복원) · `gear`(명령줄) · `GearApp`(메뉴 막대·전역 단축키·알림·편집 화면).
  `swift test` 30개 통과(05:08). 설명서 `README.md`, 빌드·설치 `scripts/build-app.sh [--install]`.
- **집 맥 설치**: `~/Applications/Gear.app`(번들 id `com.yohangwak.gear`, Apple Development 인증서 서명, 실행 중) · `~/.local/bin/gear` → 앱 안의 `gear-cli` · 프리셋 `~/.config/gear/presets.json` · 기록 `~/Library/Logs/Gear/gear.log`.
- **실사용 확인**: 요한님이 Orca 의 claude 세션에서 05:12:17 `⇧⌥3` → 05:12:24 fable 적용, 05:12:29 `⇧⌥1` → 05:12:36 opus 적용(앱 기록). **각 7초.**
- **내 통합 시험**(시험용 세션에 대상을 직접 지정): Orca·Ghostty × claude·codex 네 조합 전환, 한 줄 초안 보존, 전환 전후 `~/.claude/settings.json` 해시 동일, codex `config.toml` 은 `apply` 직전·직후 해시 동일, claude 권한 확인 창이 뜬 상태에서는 거부(창 그대로·시험 파일 미생성), codex 여러 줄 초안이면 거부(초안 그대로).

## 동작 방식과 근거 (전부 2026-10-05 22:15 ~ 10-06 05:10 KST 실측, claude 2.1.289 · codex 0.160.0 · Ghostty 1.3.1 · Orca 1.4.220)

**claude**
- `/model <모델>` · `/effort <단계>` 가 인자를 받는다. 둘 다 새 세션 기본값까지 저장한다: `/model` → `~/.claude/settings.json` 의 `model`, `/effort` → `modelSettings.<모델 id>.effortLevel`(모델별. 최상위 `effortLevel` 은 안 바뀜).
- 기본값 파일만 되돌려도 전환한 세션은 그대로, 옆 세션도 안 따라 바뀐다 → 전환 전 파일을 잡아 뒀다가 기본값 키만 되돌린다(`ClaudeDefaults.swift`).
- `Ctrl+S` = 쓰던 글 보관, 명령이 끝나면 되돌려짐(`Draft restored`). 명령 두 개면 **명령마다** 다시 눌러야 한다. 순서: `^S` `/model X` Enter `^S` `/effort Y` Enter.
- 입력창 판정: 가로줄(`─`) 바로 아래에서 `❯` 로 시작하는 줄이 «있음». 권한 확인 창의 선택 표시는 ` ❯ 1. Yes`(들여쓰기, 위가 가로줄 아님).

**codex**
- `/model <모델> <effort>` 는 **명령이 아니라 일반 프롬프트로 전송된다**(YOLO 모드 세션에 그대로 들어갔다). 선택창만 된다.
- 선택창: 모델은 숫자 키. effort 목록에서 **숫자 키 = 기본값까지 저장**, `Enter` = 기본값 저장, **`s` = 이 세션만**. 처음 커서는 현재 모델이면 현재 effort, 다른 모델이면 그 모델 기본값. 목록은 위아래 순환.
- 기준점: 5번 행(More reasoning…)에 들어갔다 Esc → 커서가 5번 행에 고정 → 위로 `5 − 행번호` 번 → `s`.
- 모델 순서 = `~/.codex/models_cache.json` 에서 `visibility=="list"` 를 `priority` 오름차순(선택창 8개와 일치).
- 쓰던 글 한 줄 보존: `^E` 공백 `^A` `^K` … 끝난 뒤 `^Y` Backspace. 여러 줄은 한 줄만 지워져 남은 줄이 `/model` 과 섞인다 → `/model` 입력 후 팝업 설명문 `choose what model and reasoning effort` 가 «보임»을 확인하고 Enter(안 보이면 되돌리고 중단).
- 작업 중(turn 진행 중)에도 전환된다.
- 입력창 판정: `›` 로 시작하는 줄이 있고, `› 1. …` 꼴(승인 창·선택창)이 «없음».

**Ghostty**
- 입력: AppleScript `perform action "text:…" on <terminal>` 가 pty 에 바이트를 그대로 쓴다(제어 문자는 `\xNN`). `input text` 는 붙여넣기로 감싸지고, `send key` 는 화살표·숫자 이름을 모른다.
- 화면: 접근성 `AXTextArea` 값(손쉬운 사용 권한 필요).
- 대상: 맨 앞 창의 `focused terminal` 의 id·제목·폴더. 제목에 `claude`/`codex` 가 없으면 폴더로 프로세스를 찾는다.

**Orca**
- 🔴 화면에 떠 있는 워크스페이스는 CLI 가 안 준다 → 상태 DB `~/Library/Application Support/orca/profiles/<activeProfileId>/profile-state.db`, `profile_state_documents` 의 `domain='workspaceSession'` → `$.activeWorktreeId`·`$.activeTabId`. 그다음 `orca terminal list --include-visual-layouts --json` 에서 탭 → `activeLeafId` → 핸들. 상세 `ai-assistant` 의 `infra/orca.md` 맨 끝 절.
- 🔴 에이전트 종류는 목록의 `agentIdentity` 로 가리면 안 된다(대기 중 null). 터미널의 `ORCA_TERMINAL_HANDLE` 환경변수를 가진 프로세스 중 바깥쪽 에이전트로 가린다(`AgentProcesses.agent(orcaHandle:)`).
- 입력 `orca terminal send --terminal <핸들> --text …`/`--enter`, 화면 `orca terminal read --terminal <핸들> --screen --json`(`source=="screen"` 일 때만 신뢰). codex 입력창 글은 `tail` 에서 빠지고 `draft` 로 온다.

## 🔴 막힌 것 / 아직 안 푼 것

1. **속도 7초.** 원인은 재지 않았다 — 아래는 **후보**다(코드에서 센 것, 측정 아님):
   - 고정 대기: claude 계획 350+1200+350+600 = 2.5초, 기본값 복원 대기 900+1500 = 2.4초(이게 끝나야 알림이 뜬다).
   - 단계마다 프로세스 생성: Orca 는 `orca` CLI(bash 스크립트)를 감지에 2~3회 + 입력 6회 + 화면 읽기 1회, Ghostty 는 `osascript` 를 단계마다.
   - codex 는 선택창 4단계마다 화면 확인(200ms 간격 폴링).
   먼저 단계별 시간을 재고 나서 줄일 것. 시도해 볼 것: 알림을 복원 전에 띄우고 복원은 뒤에서 · 고정 대기를 화면 확인으로 교체 · 한 번에 묶어 쓰기(⚠️ 한 번에 많은 바이트가 가면 claude 가 붙여넣기로 볼 수 있다 — 미실측) · `/model` 한 줄로 effort 까지 되는지(claude 바이너리에 `with ${effort}` 문구가 있어 **후보**, 미실측) · Ghostty 는 `osascript` 대신 프로세스 안 `NSAppleScript` · Orca CLI 호출 수 줄이기.
2. **claude 의 effort 올림/내림 단축키**: 바이너리에 `chat:increaseEffort`·`chat:decreaseEffort` 액션 이름은 «있음». 기본 키는 못 찾았고, 그 둘을 걸러 `false` 를 돌려주는 함수가 있다(무슨 판정인지 미확인 — 「키바인딩 불가」일 수 있다). `~/.claude/keybindings.json` 은 없다. **실제 세션에서 시험한 적 없다.** codex 는 keymap 에 `increase_reasoning_effort`·`decrease_reasoning_effort` 가 있다(기본 키 미확인).
3. **Orca 상태 DB 의 반영 지연**: 워크스페이스를 옮긴 직후 DB 가 얼마나 늦는지 못 쟀다(내 표본 6회 동안 화면 이동이 없었다). 늦으면 엉뚱한 세션에 전환이 간다. 알림에 대상 이름이 뜨는 것이 현재 유일한 방어.
4. **Option+P**(claude 내장 선택창)가 요한님 Ghostty·Orca 에서 안 되는 원인: 확정 안 함. Ghostty `macos-option-as-alt` 미설정, Orca `terminalMacOptionAsAlt=auto`, 한글 입력 상태가 **후보**. 지금 방식에는 필요 없어 넘어갔다.

## 다음 단계 (순서대로)

1. **옮기기** — 원본을 이 repo 로 복사하고(`.build/`·`dist/` 제외), `swift build && swift test` 가 30개 통과하는지 먼저 본 뒤 첫 커밋. 그다음 개명.
   `rsync -a --exclude .build --exclude dist /Users/yohan/orca/workspaces/ai-assistant/model-picker/apps/gear/ <이 repo 안 위치>/`
2. **개명 Gear → ModelSwitch** — 패키지·타깃·번들 id(`com.yohangwak.modelswitch`)·`GEAR_CONFIG`·핫키 서명 `'GEAR'`·문구·설정 경로(`~/.config/gear` → 새 경로, 기존 파일 이전)·기록 경로·명령 이름. 그리고 집 맥의 옛 설치를 정리: Gear 종료 → `~/Applications/Gear.app`·`~/.local/bin/gear` 제거 → 새 앱 설치. ⚠️ 번들 id 가 바뀌면 자동화·손쉬운 사용 권한을 요한님이 다시 허용해야 한다(Ghostty 용). 옛 앱과 새 앱이 같이 떠 있으면 같은 단축키를 두고 다툰다 — 반드시 옛 것부터 끈다.
3. **속도** — 위 1번. 요한님이 가장 강조한 것.
4. **프리셋 단어 빼기**(내 권장, 승인됨) — 기본·가볍게·최고 대신 `Opus · high` 처럼 모델·effort 를 표시하고, 이름은 선택 항목으로.
5. **결과 확인** — 전환 뒤 화면을 다시 읽어 실제 바뀐 모델을 알림에 표시(지금은 «보냈다»만 알린다).
6. **effort 올림/내림 단축키** — 위 2번을 먼저 실측. claude 에 쓸 수 있는 키가 없으면 `/effort <다음 단계>` 로 구현.
7. codex `max`·`ultra`, effort 4단계뿐인 모델(기준 행 없음 — 숫자 키로 고르고 `config.toml` 의 두 줄을 되돌리는 방식이 후보), 앱 아이콘, 로그인 시 자동 실행.
8. 새 세션을 프리셋으로 여는 명령(같은 프리셋 파일로 `claude --model … --effort …` / `codex -m … -c model_reasoning_effort=…`).
9. **일반화**(며칠 이상 걸리는 설계 — 전역 규칙의 🔴 설계 레드팀 게이트를 먼저 돌리고 계획 문서에 처분을 남길 것):
   - 「터미널」(맨 앞 세션 찾기·바이트 쓰기·화면 읽기)과 「에이전트」(전환 키 순서·입력창 판정)를 따로 끼울 수 있게 분리. 에이전트 쪽은 이미 터미널과 무관하다.
   - 터미널 추가 후보: iTerm2 · Terminal.app · tmux(→ 어떤 터미널 앱에서든) · 그 뒤 VS Code/Cursor(별도 확장 필요). ⚠️ **하나도 실측하지 않았고 순서는 근거 없는 추측이다.**
   - 문구가 전부 한국어로 박혀 있다 → 영어 기본 + 9개 언어, OS 언어 자동 선택(요한님: «우리 candlelight 처럼»; `~/Repos/yohangwak/candlelight` 는 `Sources/Candlelight/Resources/*.lproj` 방식).
   - 배포(공증 서명·Homebrew·자동 업데이트)는 🔴 승인 필요 칸.

## 함정 — 이 세션에서 실제로 밟은 것

1. **대상을 직접 지정한 시험은 감지 경로를 안 탄다.** 내 통합 시험이 전부 `--orca <핸들> --agent claude` 였어서, 실제 단축키 경로의 `agentIdentity` null 버그를 요한님이 먼저 밟았다. 감지는 `gear where`/`gear doctor` 로, 그리고 **열린 터미널 전체에 대해** 따로 확인할 것.
2. **시험 세션의 `/model`·`/effort`·codex 숫자 키는 요한님의 전역 기본값을 바꾼다.** 내가 세 번 바꿨다가 되돌렸다(opus-5-5 effort, codex effort, 기본 모델). 시험은 «현재 기본값과 같은 값»으로 하거나, 끝나면 `jq '{model, modelSettings}' ~/.claude/settings.json` 과 `config.toml` 의 `model`·`model_reasoning_effort` 를 처음과 대조할 것. 요한님은 세션·워커를 여럿 동시에 띄운다 — 바뀐 몇 초 사이에 뜬 것은 그 값으로 시작한다.
3. **실제 프리셋으로 단축키를 합성하면 요한님이 보고 있는 세션에 들어간다.** 단축키 경로 시험은 `GEAR_CONFIG` 로 「에이전트 설정이 없는 프리셋」 파일을 가리켜서(감지까지만 가고 아무것도 안 보냄) 했다. 키 합성은 `osascript -e 'tell application "System Events" to key code 18 using {…}'` 가 통했다.
4. **에이전트가 못 뜨고 셸로 떨어져도 `terminal wait --for tui-idle` 은 `satisfied:true`.** codex 에 없는 플래그 값을 줬다가 뒤이은 `send` 가 zsh 에 명령으로 들어갔다. 보내기 전에 `--screen` 으로 에이전트 화면인지 볼 것.
5. **Ghostty 에 시험 창을 만들면 Ghostty 가 맨 앞으로 온다.** 끝나면 내가 만든 창만 id 로 닫고(`close window (first window whose id is "…")`) `tell application "Orca" to activate`. 요한님 Ghostty 창(터미널 3개)은 건드리지 않는다. `command` 로 띄운 창은 제목이 `👻`·폴더가 빈 값이라 감지가 실패한다(시험 한정 — 대상을 직접 지정).
6. `script -q <파일> claude` 의 기록은 **30초마다** 써진다. 직후에 읽으면 «안 바뀜»으로 보인다. Ghostty 화면은 `gear doctor --ghostty <id> --agent … --screen` 으로 읽는다.
7. 맥 파일 시스템은 대소문자를 안 가린다 — 번들 안에 `Gear` 와 `gear` 를 같이 넣었다가 앱 실행 파일이 명령줄 도구로 덮였다. 지금은 `gear-cli`.
8. `ps -axEww` 출력(환경변수)에는 비밀이 섞여 있을 수 있다. 화면·기록에 찍지 말 것(코드도 메모리에서만 본다).
9. `brain-note.py save` 가 rc=2 로 멈춘 두 번: ① 내 읽기 기준보다 main 이 앞섬 → `read --reset --path …` 후 재시도 ② 초안 끝에 빈 줄 → 줄 끝 공백·끝 빈 줄 제거. 출력을 `grep` 으로 걸러 보다가 첫 실패를 못 봤다 — 종료코드를 같이 볼 것.

## 정정 기록 · 기각된 가설

- ❌ 「핸들 없는 `orca terminal show`(워크트리 밖) = 화면의 활성 터미널」 — 기각. 20분 넘게 `terminal list` 첫 행만 돌려줬고 화면은 다른 워크스페이스였다.
- ❌ 「`agentIdentity` 로 에이전트 종류를 안다」 — 기각(위).
- ❌ 「codex 한 줄 초안이 사라졌다」 — 내 조회기 오류. `tail` 만 보고 `draft` 를 안 봤다. 초안은 있었다.
- ❌ 「화면을 못 읽는 터미널에서는 확인 없이 보낸다」 — 내가 처음에 넣었다가 제거. 권한 확인 창에서 Enter 가 "Yes" 를 누른다. **입력창이 «보일 때만» 보낸다는 조건을 느슨하게 만들지 말 것**(속도를 줄이다가 이걸 건너뛰기 쉽다).
- ❌ 「codex effort 를 숫자 키로 고른다」 — 기본값까지 저장된다. `s` 로만.
- ❌ 「내장 Option+P 를 살리면 충분하다」 — 요한님 환경에서 불안정. 전역 단축키로 방향을 바꿨다.
- ⚪ codex `config.toml` 이 시험 시간대에 두 번 바뀌었다(22:42, 그 뒤 한 번). `apply` 직전·직후 해시는 4회 동일했고 `model`·`model_reasoning_effort` 줄은 그대로였다. 원인 미확인(후보: codex 가 시작할 때 쓰는 `[tui.model_availability_nux]`).

## 접근

- 원본 코드(읽기 전용으로): `/Users/yohan/orca/workspaces/ai-assistant/model-picker/apps/gear/`
- 설치본: `~/Applications/Gear.app` · 기록 `~/Library/Logs/Gear/gear.log` · 프리셋 `~/.config/gear/presets.json`
- 명령: `gear list` · `gear where` · `gear doctor [--orca <핸들>] [--screen]` · `gear plan <번호> <claude|codex>` · `gear apply <번호> --orca <핸들> [--agent …]`
- 되돌리기: 앱 종료(메뉴 → 종료) 후 `~/Applications/Gear.app`·`~/.local/bin/gear`·`~/.config/gear` 삭제. 시스템에 남는 다른 변경 없음.
- 판정 예약: 없음.

## 인계 (비서실장 소관)

- (없음)
