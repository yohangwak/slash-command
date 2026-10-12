# Slash Command — 할 일 · 이어받기

마지막 갱신: 2026-10-12 23:40 KST (10-11: 화면 개편 #16 · 9개 언어 #17 · `run` 확대 #18 · 확인한 판 #19 · 실기로 찾은 결함과 cursor `run` · 낮은 창 #21. 10-12 새벽: grok 1.0.50 #23 · opencode 2 #24 · WezTerm · kitty · tmux 단축키 #25. 10-12 오전: iTerm2 #27 · 모르는 키 보존 #28 · Orca 안 tmux · opencode 2 `run` · variant 없는 모델 #29. 10-12 밤: 자식 프로세스 기다리기 · 자동화 허용 창 #31 · 권한 화면 이름 #32 · Orca 화면 나무 #33). 이 파일은 main 에 있다.

## 새 대화에서 이렇게 말하면 이어진다

> slash-command repo 의 `TODO.md` 를 끝까지 읽고 이어서 진행해줘.

(비서 기록은 `ai-assistant` 의 `log/2026-10-10-*slashcommand*` · `log/2026-10-11-*slashcommand*` · `log/2026-10-12-*slashcommand*`.)

## 지금 상태

- **main = `29e7e32`(PR #33, 2026-10-12 밤).** 테스트 329개(Xcode 가 있는 맥에서 — 집 맥 2).
- **네 맥 모두 `29e7e32` 빌드다**(2026-10-12 23:21 설치, 실행 파일 sha256 `95e692b2…`, 로그인 항목 켬). 오전에 미뤄 둔 «iTerm2 가 깔린 두 맥» 도 입력 방송을 실제로 켠 상태의 거절을 실기로 본 뒤 깔았다.
- **2026-10-12 밤에 들어간 것** — 요한님이 집 맥 2 의 화면 잠금을 끄고(«집에 두는 컴퓨터라 그냥 잠금 안 되게 … AI 에이전트가 컴퓨터 사용 필요할 때 쓸 컴퓨터») «필요한 거 · 해야 하는 거 · 하면 좋은 거 모두 진행» 을 맡겼다. 설치본에 «실제 키 입력»(System Events 의 ⇧⌥번호)을 넣어 가며 찾은 것:
  - **입력 방송의 거절(오전의 미확인 → 확인)**: iTerm2 에서 방송을 메뉴로(현재 탭 · 모든 탭) · 단축키 ⌥⌘I 로 켜면 전환은 «Not sent: iTerm2 Broadcast Input is on …» 으로 거절되고 옆 칸에는 아무것도 들어가지 않았다. 메뉴를 열지 않고 단축키로 켜도 체크 표시는 바로 읽혔다. 「Toggle Broadcast Input to Current Session」 은 «모른다» 로 읽혀 역시 거절한다. 양성 대조: 방송이 켜진 채 AppleScript 로 쓰면 옆 칸에도 들어간다(그래서 이 확인이 필요하다). iTerm2 는 방송을 켤 때 확인 시트(«Keyboard input will be sent to 2 panes …»)를 띄운다 — OK 를 누르기 전에는 아직 꺼져 있다.
  - **가끔 7초 멈췄다 실패(#31)**: 자식 프로세스(`wezterm cli` · `tmux` · `kitty @` 등)가 끝난 것을 `waitUntilExit()` 가 놓칠 때가 있었다 — 5초 제한까지 기다리다 «읽지 못했다» 로 끝나고 선택창이 열린 채 남았다(WezTerm 실제 키 5번에 3번. 표본: 자식 없이 `waitUntilExit` 에 멈춘 스레드. 고치기 전 코드에서는 새 테스트가 `/usr/bin/true` 200번 중 2번을 놓친다). 끝남은 이제 `terminationHandler` 로 안다. 덤으로 호출 하나가 약 65ms → 자식이 쓴 시간이 됐다: WezTerm 전환 1.3초 → 0.27초, iTerm2 안의 tmux 1.4~1.6초 → 0.22~0.39초, kitty 0.65초.
  - **자동화 허용 창이 5초 뒤 사라짐(#31)**: 처음 누르면 뜨는 «Slash Command 가 iTerm 을 제어» 창이 스크립트의 응답 제한(5초)과 함께 사라지고 답도 남지 않았다(누를 때마다 5초짜리 창). 이제 스크립트를 보내기 전에 허락을 확인하고(`AEDeterminePermissionToAutomateTarget`), 아직이면 물어서 «답할 때까지» 기다린다. 허용하면 그 터미널이 다시 맨 앞일 때 전환을 이어 가고(다른 앱으로 갔으면 «… is allowed now. Try again.»), 이미 거절돼 있으면 누를 때 자동화 설정 화면을 연다. 명령줄 도구도 같다(리뷰 지적으로 맨 앞 재확인을 공통 코드로). 허용 창의 설명 문구가 Ghostty 만 말하던 것도 고쳤다(9개 언어).
  - **권한 화면의 이름(#32)**: macOS 27 은 Privacy & Security 의 «Accessibility(손쉬운 사용)» 목록을 «Device Control and Data Access(기기 제어 및 데이터 접근)» 라고 부른다(27.0.1 두 대에서 확인). 앱은 이제 시스템 설정의 번역표에서 그 이름을 읽어 안내한다(못 읽으면 예전 낱말).
  - **Orca 화면 나무를 끝없이 따라감(#33)**: Orca 의 탭 줄을 접근성으로 읽는 코드에 깊이 제한이 없었다. 그 나무는 창 아래에서 앱 요소가 다시 자식으로 나와 끝없이 이어질 때가 있다(집 맥의 디스플레이가 꺼져 있을 때 `where --bundle com.stablyai.orca` 가 스택 넘침으로 죽었다 — 6만 5천 겹. 같은 날 10:48 의 충돌 기록도 같은 자리, 그때는 내가 알아채지 못했다. `b52fb46` 빌드도 같았다). 이미 본 요소로는 다시 들어가지 않고 깊이 150 · 요소 3만의 상한을 둔다. 상한에 걸리면 «모른다» 로 두고 상태 DB 로 물러난다. 네 맥에 앱 자체의 충돌 기록은 없었다.
  - **설명하지 못한 것 1건**: #31 의 첫 시도에서 허락 확인이 «묻기» 로 이어지지 않은 일이 한 번 있었다(기록에 `automation 2ms` 뒤 예전처럼 5초 창). 같은 상태에서 3번 더 해서는 나오지 않았다. 지금 코드는 허락이 «확인되지 않은» 모든 경우에 묻고, 무엇을 보았는지 기록에 남긴다(`preset 2: automation iTerm2: …`).
- **2026-10-12 오전에 들어간 것** — 요한님: «집 맥 2 에 권한 물어보는거 아무것도 안떠있는데 너가 필요한거 해야하는거 모두 집맥2에서 계속 모두 해봐». 집 맥 2 의 화면을 내가 다루는 길을 찾아(아래 「집 맥 2 의 화면을 다루는 법」) 이어서 했다:
  - **iTerm2(#27)**: `origin/yohangwak/agents` 의 조각을 main 위로 옮겼다. 맨 앞 창의 세션(`unique id` · `tty`)을 AppleScript 로 알고, 그 tty 의 에이전트로 가고, 거기서 tmux 가 앞 작업이면 그 칸으로 간다(#25 의 길). 쓰기 전마다 Shell ▸ Broadcast Input 메뉴의 체크 표시를 손쉬운 사용으로 읽어 「Send Input to Current Session Only」 일 때만 보낸다(세션이 맨 앞 창에 있을 때만 — 확인 → 메뉴 → «맨 앞 창에 있을 때만 쓰는» 한 스크립트). 집 맥 2 의 iTerm2 3.7.3 에서 codex 0.162.0 · claude 2.1.296 의 프리셋 · effort(1.3~2.6초), iTerm2 탭 안의 tmux→codex(1.4~1.6초), 앱 메뉴(`Claude Code · iTerm2` · `Codex · tmux`)를 확인. 기본값 파일 그대로. 방송을 «실제로 켠» 상태의 거절은 그날 밤에 확인했다(위).
  - **iTerm2 의 화면 줄 세기(#27, 리뷰 5회)**: `contents` 는 스크롤백까지 주고 접힌 줄을 한 줄로 잇는다 → 줄마다 차지하는 행 수를 세어 지금 화면만 남긴다. 폭을 많이 세면 «보이는» 윗줄을 버리고(11줄 칸에서 codex 선택창이 열린 채 남았다 — 실측), 적게 세면 화면 밖의 입력창이 입력을 허락한다. 그래서: 폭은 유니코드 표(`CharacterWidth` — 확실히 아는 글자만 정확히, 표보다 새 글자와 이모지 표시 선택자가 붙은 글자는 넓게) · «모호한 폭» 은 그 세션 프로필의 설정대로(iTerm2 설정 파일과 DynamicProfiles 에서 읽는다. 동적 프로필의 부모는 GUID → 이름 → 기본 프로필) · 프로필이 1칸이어도 «입력창이 보인다» 는 판정은 2칸으로 센 화면에서도 성립할 때만 통과(세션에서만 바꾼 설정은 알 수 없으므로).
  - **세션 찾기(#27)**: 창 · 탭 · 세션을 돌며 id 를 하나씩 묻던 것을 «id 들을 한 번에 받아 `session id "…" of tab i`» 로(세션 4개에서 화면 읽기 200ms → 65ms).
  - **38칸의 codex(#27)**: iTerm2 창을 나누다 찾았다 — `/model` 의 설명 줄과 effort 목록의 머리말이 둘로 접혀 «여러 줄 초안» · «effort 목록이 열리지 않았다» 로 물러났다 → 이웃한 줄을 이어 읽는다(프리셋 · effort 5번에 5번).
  - **프리셋 파일의 모르는 키(#28)**: 설정 창에서 저장하면 나중 판이 쓴 키가 사라졌다 → 맨 위 · 프리셋 · 에이전트 설정 세 층에서 읽은 그대로 다시 쓴다(프리셋을 지우거나 옮겨도 그 프리셋의 것은 그 프리셋을 따라간다).
  - **Orca 안의 tmux(#29)**: 그 터미널의 핸들(`ORCA_TERMINAL_HANDLE`)을 가진 «앞 작업» tmux 클라이언트가 보는 칸으로 간다. 서버를 그 터미널에서 띄웠으면 칸 안의 프로세스도 같은 핸들을 물려받으므로, 조상에 tmux 가 있는 것(칸 안에서 다시 띄운 클라이언트 · 칸 안의 에이전트)은 «그 터미널의 것» 으로 세지 않는다. 집 맥의 시험 터미널에서 claude 프리셋 · effort · 칸 옮기기 · 떼기 · 다시 붙이기를 확인, 설치본으로도 확인.
  - **`run` 으로 opencode 2 열기(#29)**: 그냥 연 뒤 따로 띄운 일꾼(`follow`)이 «그 터미널» 에 입력창이 뜨기를 기다렸다가 단축키와 같은 전환을 돌린다. 그 터미널은 환경변수로만 안다(tmux 칸 · Orca · iTerm2 · WezTerm · 원격 제어를 켠 kitty — **Ghostty 는 안 된다**: 세션이 자기 터미널을 알 길이 없다). 일꾼은 «연 프로세스»(pid + 시작 시각)가 살아 있고 앞 작업일 때만 따른다. 결과는 기록 파일(`~/Library/Logs/SlashCommand/slashcommand.log`)에 한 줄. 집 맥의 Orca 에서 2.0.25 로 확인, 설치본으로도 확인.
  - **variant 없는 opencode 모델(#29)**: Big Pickle 같은 모델에서 `/variants` 는 대화상자 대신 «No variants available» 알림을 띄운다. 전에는 프리셋이 모델을 바꾸고도 «대화상자가 열리지 않았다» 며 실패로 알렸다 → 모델만 맞추고 경고로 알린다. effort 는 1초 안에 «이 모델에는 단계가 없다».
  - **Ghostty 가 응답하지 않을 때의 5초 제한**(전에 «확인 못 함» 으로 남긴 것): 집 맥 2 에서 Ghostty 를 SIGSTOP 으로 멈춰 재 봤다 — 5.16초 뒤 `AppleEvent timed out (-1712)` 로 끝났고, 다시 돌리자 0.35초.
- **2026-10-12 에 들어간 것** — 요한님: «로그인 두개 다 했는데 확인해볼래 · 집맥에 3가지 다 열었어 필요한거 해봐 · 남은 항목들 모두 진행해줄래 너의 권장대로». 로그인 둘(grok `~/.grok/auth.json` 05:38 · opencode «OpenCode Go stored»)과 집 맥 2 의 세 터미널(05:46~05:47 에 뜬 프로세스)을 확인하고 이어서 했다:
  - **grok 1.0.50(#23)**: main 은 «입력창이 안 보인다» 로 아무것도 못 했다. 막 연 세션은 안내 줄 자리에 채널 표지만 있고(`[stable]`, 낮은 창은 `Grok Build  1.0.50 [stable]`), 권한 모드가 이름표 뒤에 붙고(`Grok 4.7 (high) · always-approve` — Orca 가 그렇게 연다), 20줄보다 높은 창은 상자와 안내 줄 사이에 빈 줄이 있고, 20줄 이하의 창은 안내 줄이 작업 중에도 `Ctrl+x:shortcuts` 뿐이다 → 작업 중은 입력창 위의 상태 줄(`⠹ … [stop]`)로도 가린다. 고친 뒤 Orca · tmux 120×30 · tmux 110×18 에서 프리셋 · effort · 작업 중 거절을 확인(0.33초), `config.toml` 은 매번 그대로. `run 2 grok`(`grok -m … --reasoning-effort …`)은 기본값 파일을 바꾸지 않았다(cursor 와 다르다 — 지킬 것이 없다).
  - **opencode 2.0.25(#24)**: Go 로그인 뒤 제공자가 둘이 되자 대화상자가 예전 판처럼 «이름 + 제공자» 로 걸러졌다(어제의 «안 된다» 는 제공자가 하나일 때의 모습이었다). 고친 것 — ① 걸러진 행은 «가장 비슷한 것» 순서가 아니다(`GLM-5.3 OpenCode Go` 를 치면 `GLM-5.3-Flash` 가 맨 위). 맨 위 행만 받던 것을, 같은 행까지 ↓ 로 세어 내려가 고르고 끝에 모델 줄이 프리셋과 같은지 확인하게 했다(커서는 글자로 안 보인다 — 둘째·셋째 행을 6번에 6번). ② 제공자가 하나뿐이면 이름으로만 걸러지고 행에 제공자 칸이 없다 → 먼저 «제공자가 무엇인지» 를 대화상자에서 확인한다(지금 모델 줄에서 뒤 낱말을 지워 가며 `●` 가 붙은 지금 모델의 행과 같아질 때까지). 프리셋이 그 제공자로 끝날 때만 이름으로 고른다. 1.18.35(집 맥 2)에서도 확인.
  - **WezTerm · kitty · 그 안의 tmux 에 단축키(#25)**: 맨 앞 세션을 WezTerm 은 `wezterm cli`(포커스 pane → tty), kitty 는 원격 제어(`kitty @ ls`), 그 tty 에서 tmux 클라이언트가 «앞 작업» 이면 그 클라이언트가 보는 tmux 칸으로 찾는다. 집 맥 2 에서 WezTerm→codex · WezTerm→tmux→claude · kitty→codex · kitty→tmux→codex 의 프리셋 · effort 를 단축키가 가는 길(`--bundle <번들 id>`)로 확인(1.1~1.8초), 기본값 파일 그대로. kitty 는 사용자가 원격 제어를 켜야 한다(`allow_remote_control socket-only` + `listen_on unix:/tmp/kitty`).
  - **11줄짜리 창의 claude(#25)**: 선택창의 맨 아래 안내 줄이 잘려 선택창을 못 알아보고 «열리지 않았다» 며 선택창을 열어 둔 채 끝났다(2번에 2번 — 전부터 있던 결함) → 머리말과 커서 행이 보이면 닫고 물러난다(프리셋은 명령 방식으로, effort 는 «창이 낮다» 고 알린다).
- **2026-10-11 저녁에 들어간 것(#21)** — 요한님: «필요한 건 네가 다 설치하면 되는 것 아니냐, 로그인은 명령어만 알려 달라». 그래서 집 맥에 에이전트와 tmux 를 깔고 따로 연 시험 세션에서 실제로 돌렸다:
  - **cursor(2026.10.01-e373342)**: `--yolo` 로 연 세션은 모델 줄 오른쪽에 `Run Everything` 이 붙어, 전환은 됐는데 «바뀌지 않았다» 고 멈췄다(4번에 4번) → 모델 줄을 그 앞까지만 읽는다. effort 만 바꿀 때 목록이 막 열린 순간의 커서(맨 윗줄 `Auto`)에서 Tab 을 눌렀다(8번에 2번) → 커서가 지금 모델에 놓인 것을 보고 누른다(고친 뒤 16번에 16번). 스피너와 입력 줄 사이에 `Tip:` 줄이 끼면 작업 중인데 전환했다 → `ctrl+c to stop` 안내와 몇 줄 위의 스피너까지 본다.
  - **antigravity(1.3.3)**: 프리셋 3개 · effort 올림/내림 모두 됐다(0.37초). 고칠 것 없음.
  - **`run <번호> cursor`**: `cursor-agent models` 에서 id 를 찾는다. 🔴 cursor 는 `--model` 로 연 모델을 새 세션 기본값으로도 저장한다(실측) → 따로 띄운 프로세스(`keep-defaults`)가 1분 동안, 기본값이 «연 모델» 로 바뀌면 연 전 값으로 되돌린다(다른 세션이 다른 모델로 바꾼 것은 그대로 두고, 겹쳐 연 세션들은 첫 열기 전의 값을 같이 기준으로 쓴다 — 리뷰 지적으로 고침). agy 는 `--model` 로 열어도 기본값이 그대로였다.
  - **낮은 창의 claude**(tmux 90×14): 선택창에 커서 행 하나만 보이고 나머지는 `… +9 models` 로 접힌다. 전에는 명령 방식(기본값을 바꿨다 되돌림)으로 갔다 → 커서를 맨 위로 올린 뒤 내려가며 찾아 «이 세션만» 으로 확정한다(1.9~3.4초, 기본값 파일은 그대로). 🔴 처음에는 지금 자리에서 아래로만 찾아 `Opus 5.5` 대신 `Opus 5` 를 골랐다 — 앞머리가 같은 행이 여럿이라 «맨 위에서부터» 가 필수다.
  - **opencode 2.0.25**: 자리 표시 문구가 달라 «입력창이 안 보인다» 던 것은 고쳤다. variant(effort) 올림/내림은 된다. **모델 전환은 안 된다** — 모델 대화상자가 제공자 이름으로 걸러지지 않고 행에 제공자 칸이 없다(아래 4번). `run` 도 안 된다(여는 옵션에 `--model` 이 없다 — 그렇게 알린다).
  - Homebrew 로 깐 에이전트의 판을 경로에서 읽는다(`Caskroom/cursor-cli/<판>` · `Cellar/opencode/<판>`).
- **2026-10-11 아침에 들어간 것**(요한님이 메뉴·설정 창 사진을 보내며 «디자인 uxui 등 개선 추가 수정 버그등 전체적으로 살펴보고 진행» · «9가지 언어 … 시스템 언어 자동» 을 요청):
  - **메뉴(#16)**: 프리셋 한 줄이 화면 폭만 했다 → 맨 앞 세션의 에이전트를 알아내(아무것도 보내지 않는다) 그 에이전트에 «지금 누르면 되는 값» 만 보여 준다(`Claude Code · Orca` 아래 `opus · high`). 권한·단축키 줄은 문제가 있을 때만 생긴다.
  - **설정 창(#16)**: 묶음별 칸 · 프리셋은 접힌 한 줄(전에는 3개 중 1개만 보였다) · 쓰는 에이전트만 「Add Agent」 로 · 높이 조절 · 바뀐 것이 있을 때만 Save/Revert.
  - **버그(#16)**: 독립 검토(코드만 읽은 다른 에이전트)가 낸 14건을 코드로 판정해 고쳤다 — 프리셋 파일을 못 읽은 채 저장하면 빈 목록으로 덮어쓰던 것 · 창을 다시 띄우면 저장 안 한 편집이 사라지던 것 · 프리셋 삭제 때 범위 밖 접근 · 글 상자에서 ⌘C/⌘V/⌘A/⌘Z 가 안 듣던 것(주 메뉴가 없었다) · Shift 만으로 단축키를 잡을 수 있던 것 · 링크로 걸린 프리셋 파일이 보통 파일로 바뀌던 것 · Ghostty AppleScript 에 시간 제한이 없던 것(이제 5초) · 못 잡은 단축키를 다시 안 잡던 것 · 알림이 앞 알림의 사라짐에 같이 지워지던 것 · 기록 파일이 끝없이 자라던 것(2MB 에서 넘긴다) 등.
  - **언어(#16·#17)**: 영어가 기준(`loc("영어 문장", 값…)`), 번역은 `Resources/<언어>.lproj`, 시스템 언어 순서로 자동 선택. **9개**: 영어 · 한국어 · 일본어 · 중국어(간체) · 스페인어 · 프랑스어 · 독일어 · 포르투갈어 · 아랍어. 한국어 말고는 기계 번역(원어민 검수 없음). 명령줄 도구의 자체 출력·기록 표지는 영어 고정.
  - **`run`(#18)**: antigravity · opencode 도 프리셋으로 새 세션을 연다(각 CLI 의 모델 목록에서 id 를 찾는다). cursor 는 저녁의 #21 에서.
  - **확인한 판(#19)**: claude 2.1.296 · codex 0.162.0 — 따로 연 시험 세션에서 실제로 전환해 확인(아래 「실기 확인」).
- **깔린 앱**: 네 맥(집 맥 · 집 맥 2 · 사 맥 · 맥북) = main `29e7e32` 빌드(2026-10-12 23:21, 실행 파일 sha256 `95e692b2…`, `Apple Development` 서명, 로그인 항목 켬). 그 tar 는 집 맥 2 의 `/tmp/SlashCommand-29e7e32.tar` 에 뒀다(재시작하면 사라진다 — 없으면 다시 빌드). 설치본 확인: 집 맥 2 에서 iTerm2 안의 tmux 에 실제 키 4번(0.27~0.37초), 집 맥에서 `where --bundle com.stablyai.orca`(종료 코드 0).
- **집 맥에 깔린 에이전트·도구(2026-10-12 조회)**: claude 2.1.296 · codex 0.162.0 · cursor-agent 2026.10.01-e373342(로그인됨) · agy 1.3.3(로그인됨) · opencode 2.0.25(Homebrew, **OpenCode Go 로그인됨** — 제공자가 Go · Zen 둘) · grok 1.0.50(**로그인됨**) · tmux 3.8. opencode 2 는 처음 띄울 때 뒤에서 도는 서버(`opencode serve --service`)를 스스로 띄워 둔다(10-11 21:54 부터 떠 있다 — opencode 자신의 것이라 그대로 뒀다).
- **집 맥 2 의 터미널**: WezTerm · kitty · iTerm2(Homebrew cask) · tmux 3.7c. 요한님이 2026-10-12 05:46 에 그 화면에서 세 앱을 열어 줘서 그 뒤로 ssh 에서 다룰 수 있었다. 집 맥 2 의 에이전트: claude 2.1.295/2.1.296 · codex 0.162.0 · opencode 1.18.35(`~/.opencode/bin`) 등.
- **화면 언어**: 네 맥 모두 시스템 언어 1순위가 영어(`en-KR`)라 앱이 영어로 뜬다(맥북도 2026-10-11 22:59 에 확인). 한국어로 보려면 시스템 설정 → 일반 → 언어 및 지역 → 응용 프로그램에서 Slash Command 를 한국어로.
- **실기 확인**: 2026-10-11 집 맥 — claude 2.1.296 · codex 0.162.0 · cursor · antigravity. 2026-10-12 — grok 1.0.50(집 맥) · opencode 2.0.25(집 맥, 제공자 둘 / 격리 폴더로 제공자 하나) · opencode 1.18.35(집 맥 2) · WezTerm · kitty · 그 안의 tmux(집 맥 2, claude 2.1.295 · codex) · iTerm2 3.7.3 과 그 안의 tmux(집 맥 2, claude 2.1.296 · codex 0.162.0 — 보통 창 · 38칸 칸 · 11줄 칸 · 폭 설정이 다른 두 프로필) · Orca 안의 tmux 와 `run` 의 opencode 2(집 맥). 모두 따로 연 시험 세션에서, 시험한 에이전트의 기본값 파일은 시험 전 사본과 같거나 사본으로 되돌렸다(아래 「내가 바꿔 둔 것」). 2026-10-12 밤 — 설치본에 실제 키(집 맥 2): WezTerm→codex 13번에 13번(261~284ms) · kitty→codex 6번에 6번(641~691ms) · iTerm2 안의 tmux→codex 4번에 4번 · 원격 제어가 꺼진 kitty 는 그렇게 알림 · 권한 없는 iTerm2 보통 탭은 그 설정 화면을 엶. 기본값 파일(`~/.claude/settings.json` · `~/.codex/config.toml`) 그대로.
- GitHub 저장소 `yohangwak/slash-command`. 자동 리뷰어(pullfrog)의 승인 체크(`pullfrog-approval`)가 통과해야 머지된다 — 우회 머지는 하지 않는다. 리뷰 1회 3~8분(길면 18분).
- iTerm2 코드는 #27 로 main 에 들어왔다(`origin/yohangwak/agents` 는 개명 전의 옛 보관본 — 더 볼 일 없다).

## 요한님 손이 필요한 것

1. **집 맥 2 화면에 떠 있는 암호 창에 암호 넣기** — 시스템 설정 → 기기 제어 및 데이터 접근(옛 «손쉬운 사용») 목록에서 Slash Command 스위치를 내가 눌러 «Privacy & Security is trying to modify your system settings» 암호 창까지 띄워 뒀다(2026-10-12 23:26). 암호는 사람만 넣을 수 있다. 창이 사라졌으면 앱 메뉴의 「… 켜기…」 줄이나 그 맥의 iTerm2 · Ghostty 에서 단축키를 누르면 그 화면이 다시 열린다. 켜지면 내가 할 것: 설치본으로 iTerm2 의 보통 탭에서 실제 키(방송 확인을 거치는 길) · Ghostty 에서 허용 창 → 전환.
2. **맥북의 같은 권한**: 꺼져 있다(2026-10-11 23:00 관측). 사 맥은 확인하지 못했다. 집 맥은 켜져 있다. 설정 창 맨 위 「Permissions」 의 「Open Settings…」 — Ghostty 화면 읽기 · Orca 탭 줄 · iTerm2 의 입력 방송 확인에 쓴다(iTerm2 안의 tmux · WezTerm · kitty 에는 필요 없다).
3. **새 화면을 눈으로 한 번 봐 주기.** 메뉴와 설정 창은 그림으로 뽑아 확인했을 뿐 실제 화면에서 눌러 보지 못했다: 설정 창의 글 상자에서 ⌘V 가 되는지 · 프리셋 줄을 눌러 펼쳐지는지 · 저장 뒤 단축키가 그대로인지 · 알림이 뜨는 자리.
4. 결정이 필요한 것: 라이선스 · Developer ID 서명/공증(공개 배포를 할지) · 번역을 원어민에게 보일지.
5. 시스템 설정의 손쉬운 사용 목록에 남은 옛 ModelSwitch 항목은 − 로 지워도 된다.

## 다음 할 일 (순서대로)

1. **권한이 켜진 뒤의 실기 확인(집 맥 2)**: 설치본으로 iTerm2 의 보통 탭에서 실제 키 → 전환 · Ghostty 에서 처음 누를 때의 허용 창(«Slash Command 가 Ghostty 를 제어» — 집 맥 2 에서는 아직 물은 적이 없다) → 전환. 그리고 **집 맥의 화면이 켜져 있을 때** `slashcommand-cli where --bundle com.stablyai.orca` 가 `visible via` 에 탭 줄을 읽었다고 내는지(= 보통 상태에서 탭 줄 읽기가 #33 뒤에도 된다). `state DB (could not read the tab strip …)` 가 나오면 «탭 줄 확인 실패» 일 뿐 원인은 아직 모른다 — 그 문구는 권한 없음 · 접근성 읽기 실패 · 탭 버튼을 못 찾음 · 상한에 걸림 모두에서 나온다(화면이 꺼진 동안에도 나온다). 상한 탓이라고 하려면 그 나무의 요소 수 · 깊이가 3만 · 150 을 넘는 것을 재서 보인 뒤에만 올린다(재지 않고 상한을 풀지 않는다).
2. **Ghostty 안의 tmux**: 아직 단축키로 안 된다. Ghostty 1.3.1 의 스크립팅 사전에는 터미널의 tty · pid 가 없다(`id` · `name` · `working directory` 뿐 — 2026-10-12 사전 파일로 확인). tmux 의 포커스 표시(`client_flags` 의 `focused`)는 `focus-events on` 을 켜기 전에 붙은 클라이언트에서 낡는다(실측). 남은 길: Ghostty 가 읽어 주는 화면 글과 `tmux capture-pane` 을 대조해 «지금 보이는 것이 그 칸» 임을 확인(후보가 하나일 때만) — 어림이라 조심해서. Terminal.app 은 AppleScript 가 탭의 tty 를 주므로 tmux 가 도는 탭만이라면 #25 의 길로 된다(자동화 허용 필요, 아직 안 함).
3. **범용 목표의 나머지**(요한님: «누구나 유용하게 쓸 수 있게»): 화면을 못 읽는 터미널(Terminal.app · VS Code 등) · 서명/공증(Developer ID) · 라이선스 · 자동 업데이트 · CI(맥 러너를 쓰지 않는 조건에서 무엇을 돌릴지) · 번역 검수. 순서와 근거는 `docs/PLAN-generalization.md`.
4. **확인하지 못하고 남은 것**: 알림(HUD)이 여러 모니터에서 터미널이 있는 화면에 뜨는지(`NSScreen.main` — 집 맥 2 는 모니터가 하나다) · iTerm2 의 tmux 통합 모드(`tmux -CC`) · `run` 의 «이 터미널» 가운데 iTerm2 · WezTerm · kitty 쪽(환경변수 풀기는 단위 테스트뿐, 실기는 Orca 만) · 동적 프로필의 부모를 GUID 와 이름으로 같이 적은 경우(문서의 순서대로 고쳤고 실기로는 재지 않았다).
5. cursor 의 `Fast`: 프리셋에는 그 스위치가 없다. 단축키로 바꾸면 그 행에 기억된 값(이 맥에서는 켜짐)을 따르고, `run` 으로 열면 꺼진 id 를 고른다 — 두 길의 결과가 다르다. 프리셋에 넣을지는 쓰임을 보고(#28 로 프리셋 파일에 새 키를 넣어도 옛 판이 지우지 않게 됐다).
6. 작은 것: grok · (집 맥 2 의) opencode 는 실행 파일 경로에 판이 없어 `doctor` 가 «running unknown» 이라 한다(설치된 판은 읽는다) · 낮은 창의 claude 는 한 칸에 0.2초쯤 걸린다 · iTerm2 는 호출 하나가 15~20ms 라 화면 읽기 한 번에 65~90ms 다(잠긴 화면에서 잰 값 — 맨 앞일 때는 다를 수 있다) · kitty 를 둘 이상 띄웠을 때 맨 앞 것이 원격 제어 없이 뜬 것이면 «꺼져 있다» 고 한다(의도한 동작) · iTerm2 의 창을 방금 닫아 «현재 창» 이 없으면 `Can’t get current window` 로 읽지 못한다(iTerm2 가 맨 앞이면 생기지 않는다). · 기록의 «no Accessibility permission» 같은 영어 고정 문구는 옛 이름 그대로다(화면 문구만 #32 로 바뀌었다).

## 내가 바꿔 둔 것 (되돌릴 수 있게)

- **프리셋**(`~/.config/slashcommand/presets.json`): 2026-10-10 에 각 맥의 옛 ModelSwitch 프리셋을 옮긴 것 그대로다. 집 맥·집 맥 2 의 1~3번에는 grok·cursor·antigravity·opencode 설정이 들어 있다(2026-10-08 에 추가 — 빼려면 설정 창에서 그 에이전트 줄의 − 를 누른다).
- **깔린 앱**: 위 「지금 상태」. 그 전의 앱은 지웠다(되돌리려면 그 커밋을 다시 빌드 — 아침 것은 `2345c4e`).
- **빌드·설치 방법(지금 환경)**: 서명 인증서와 Xcode 는 집 맥 2 에 있다(사 맥·맥북은 확인하지 않았다). 집 맥(Studio)은 Command Line Tools 뿐이라 `swift build` 는 되지만 `swift test` 는 `XCTest` 가 없어 실패하고 서명은 임시(ad-hoc)가 된다. 그래서 테스트와 서명 빌드는 집 맥 2 의 임시 폴더에서 한다. **SSH 세션에서는 `codesign` 이 `errSecInternalComponent` 로 실패한다**(로그인 키체인이 잠겨 있다) — `scripts/build-app.sh` 를 로그인 세션의 일회성 launchd 작업(`launchctl bootstrap gui/<uid>`)으로 돌린 뒤 작업과 폴더를 지운다. 다른 맥에는 `tar -C dist -cf - "Slash Command.app" | ssh <맥> 'tar -C ~/Applications -xf -'`(`scp -r` 은 조용히 실패한 적이 있다). 집 맥에 Xcode 와 인증서를 두면 이 우회가 필요 없다(요한님 손).
- **시험 세션**: 2026-10-11·12 에 연 시험 터미널(Orca 의 `SC-TEST…`, 집 맥의 tmux `-L sctest`·`sctest2`, 집 맥 2 의 tmux `-L scfront`·`scit` · 따로 띄운 kitty · WezTerm 의 탭 · iTerm2 의 시험 창 · 시험용 동적 프로필 `sc-test.json`)은 모두 닫고 지웠다. codex · agy 는 시험 세션을 열 때 기본값 파일에 그 폴더의 trust 항목을 넣는다 — 시험 전 사본으로 되돌렸다. cursor 의 `cli-config.json` 도 시험 전 사본으로(모델 키가 없는 상태). opencode 의 `model.json` 은 시험 전에 없던 파일이라 지웠다. grok 의 `config.toml` 은 «처음 띄운 뒤의 상태»(grok 이 스스로 쓴 `[marketplace]` · `[ui]`, `[models]` 없음)로 뒀다.
- **집 맥 2 에서 내가 허용한 권한(2026-10-12 10:29)**: «Ghostty 가 iTerm 을 제어» (자동화). 요한님의 «필요한 거 모두 집 맥 2 에서 해 봐» 에 따라, 떠 있는 허용 창의 글을 읽어 그 창일 때만 Allow 를 눌렀다. 시험에만 쓴 것이라 필요 없으면 시스템 설정 → 개인정보 보호 및 보안 → 자동화 → Ghostty 에서 iTerm 을 끈다. 그 밖에 바꾼 권한은 없다(설치본 Slash Command 의 iTerm 허용 · 손쉬운 사용은 아직이다).
- **2026-10-12 밤의 권한 · 설정(집 맥 2)**: 화면 잠금은 요한님이 직접 껐다(22:10, `screenLock is off` — `ai-assistant/infra/macs.md`). 내가 누른 것: 설치본의 «Slash Command 가 iTerm 을 제어» 허용(22:37:59 — 그 앞에 시험으로 한 번 거절하고 `tccutil reset AppleEvents com.yohangwak.slashcommand` 로 되돌린 뒤 허용). 명령줄 경로 시험으로 «WezTerm 이 iTerm 을 제어» 를 두 번 허용했다가 `tccutil reset AppleEvents com.github.wez.wezterm` 로 지웠다(남은 것 없음). 손쉬운 사용 스위치는 눌렀지만 암호 창에서 멈췄다(켜지지 않았다).
- **집 맥에 깐 것**: grok 1.0.50(`~/.grok`, `~/.local/bin/grok` 링크 — 설치 스크립트가 `.zshrc` 를 고치지 않게 `SHELL=/bin/sh` 로 돌렸고, 같이 생긴 `~/.local/bin/agent` 링크는 지웠다) · tmux(`brew uninstall tmux` 로 지운다). 집 맥 2: `brew uninstall --cask wezterm kitty iterm2` · `brew uninstall tmux`. 세 앱의 격리 표시(`com.apple.quarantine`)는 공증을 확인한 뒤 지웠다. 집 맥 2 의 kitty 설정은 건드리지 않았다(원격 제어는 시험할 때만 `--listen-on` 인자로 따로 띄웠다).
- 맥북: Homebrew 로 깐 tmux·kitty·WezTerm·iTerm2 는 요한님 뜻대로 남겨 뒀다(2026-10-07). iTerm2 에 방송(Broadcast Input)을 켠 두 칸 창이 열려 있을 수 있다.

## 집 맥 2 의 화면을 다루는 법 (2026-10-12 에 찾은 길)

ssh 에서 띄운 프로세스는 화면 권한(자동화 · 손쉬운 사용 · 화면 기록)이 없다. 집 맥 2 의 **Ghostty** 에는 그 권한들이 예전부터 있다(옛 «집 맥» 시절의 것). 그래서 Ghostty «안» 에서 도는 실행기를 띄우고 ssh 로 일감을 넣는다:

- 띄우기: `/tmp/sc-gui`(700) 에 `queue/` · `out/` 과 실행기 스크립트(`queue/*.sh` 를 차례로 돌려 `out/<이름>.out` · `.rc` 를 남기는 반복문)를 두고 `ssh Mac-Home-2 'open -na Ghostty --args -e /tmp/sc-gui/runner.sh /tmp/sc-gui'`. 그 Ghostty 는 지난 창들(셸 탭)을 같이 되살린다 — 끝나면 시작 시각으로 가려 그 Ghostty 만 끈다.
- 그 안에서 되는 것(실측): `osascript` 로 iTerm2 · System Events 다루기 · `screencapture -x` · 디버그 빌드의 `slashcommand`(권한은 Ghostty 의 것으로 통한다 — `--bundle com.googlecode.iterm2` 가 단축키의 길을 그대로 탄다) · 앱 실행 파일의 `--menu-text`.
- 🔴 **디스플레이가 꺼져 있으면** 창 수가 0 으로 읽히고 메뉴 클릭 · 키 입력 · 캡처가 먹지 않는다(AppleScript 로 앱에 직접 말하는 것 · 접근성으로 메뉴 표시를 읽는 것 · tmux 는 된다). 2026-10-12 22:10 부터 화면 잠금은 꺼져 있어 암호는 필요 없지만, 꺼진 동안에는 세션이 잠긴 것으로 보고된다(`ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked` 가 1). **시작할 때 `caffeinate -u -t 2`(깨우기 — 0.4초 뒤 0 이 된다) → 일하는 동안 `caffeinate -d -t <초>`**(22:43 실측 2회: 깨운 뒤 창 읽기 · 실제 키 · 창 캡처 모두 됨). 오전에는 잠금이 «즉시» 였고 `caffeinate` 를 늦게 걸어 10:30:58 에 잠겼다.
- **실제 키 넣기**: `osascript -e 'tell application "System Events" to key code 19 using {option down, shift down}'`(1=18 · 2=19 · 3=20 · «=»=24 · «-»=27). 누르기 전에 맨 앞 앱이 기대한 터미널인지 확인한다(다른 앱이 앞이면 그 앱에 글자가 들어간다). 결과는 `~/Library/Logs/SlashCommand/slashcommand.log` 의 `applied …` · `failed …` · `timing …` 줄로 본다. 알림(HUD)의 글은 `tell process "SlashCommand" to value of every static text of window …` 로 읽힌다.
- **앱 «자신» 의 권한 상태**: 터미널에서 앱 실행 파일을 바로 부르면 그 터미널의 권한으로 답한다. `open -n -W -a "Slash Command" --stdout <파일> --args --automation-status <번들 id>` 로 띄워야 앱의 답이 나온다(0 허용 · -1743 거절 · -1744 아직 묻지 않음). 처음 상태로 되돌리기는 `tccutil reset AppleEvents <앱의 번들 id>`.
- **시스템 설정 화면 읽기**: `tell process "System Settings"` 에서 `set frontmost to true` → `delay 1` 뒤에 `entire contents of window 1` 을 읽어야 요소가 나온다(바로 읽으면 0개일 때가 있다 — 몇 번 되풀이한다). 암호 창(시트)의 안쪽은 읽히지 않는다. AppleScript 에서 `before` · `after` 는 변수 이름으로 못 쓴다.
- 🔴 화면을 통째로 찍지 않는다 — 그 화면에는 다른 앱(암호 관리 앱 등)이 떠 있다. `screencapture -R x,y,w,h` 로 필요한 창만.
- 🔴 실행기 안에서 «처음 말을 거는 앱» 에 AppleScript 를 보내면 허용 창이 뜬다(Finder 에 보냈다가 잠긴 화면 뒤에서 2분을 기다렸다 — 그 `osascript` 를 죽이면 창도 사라진다). 허용 창은 글을 읽어(`System Events` 의 `UserNotificationCenter` 창) 기대한 것일 때만 누른다.
- 시험용 iTerm2 창: `create window with default profile` → `write text "cd ~/Repos && codex"`. 폭 설정이 다른 창은 동적 프로필 파일(`~/Library/Application Support/iTerm2/DynamicProfiles/*.json` — `"Ambiguous Double Width"` · `"Rows"` · `"Columns"`)을 두면 iTerm2 가 바로 읽는다(`create window with profile "…"`). 창을 닫은 뒤에는 `tell window id N to select` 로 현재 창을 다시 정해야 `current window` 가 읽힌다.

## 알아 둘 함정 (다시 밟지 않게)

- 시험은 반드시 따로 연 시험 세션에서. 시험 전에 각 에이전트의 기본값 파일을 «사본» 으로 남기고(해시만 남기면 달라졌을 때 대조할 수 없다) 끝나면 대조한다: claude `~/.claude/settings.json` · codex `~/.codex/config.toml` · grok `~/.grok/config.toml` · cursor `~/.cursor/cli-config.json`(인증 정보가 들어 있다 — 내용을 출력하지 않는다) · agy `~/.gemini/antigravity-cli/settings.json` · opencode `~/.local/state/opencode/model.json`.
- 🔴 **대상(`--orca <핸들> --agent …`)은 명령에 글자 그대로 쓴다.** zsh 에서 `$T` 처럼 변수에 묶어 넘기면 한 덩이 인자가 되어 대상 지정이 통째로 빠지고, 그러면 명령은 «맨 앞 세션»(요한님이 쓰고 있는 세션)을 대상으로 삼는다. 2026-10-11 에 그렇게 넘겼다 — 그때는 `apply 2` 도 한 덩이라 사용법만 찍히고 아무것도 보내지 않았다.
- 🔴 **cursor 는 모델 목록을 «여는 것만으로» 기본값 파일을 쓴다**(2026-10-11 실측: 목록이 열린 0.2초 뒤 그 세션의 지금 모델이 파일에 적혔다). 시험 세션에서 손으로 `/model` 을 열었다 닫으면(앱을 거치지 않으면) 그 값이 기본값으로 남는다 — 그렇게 남겼다가 사본으로 되돌렸다. 손으로 연 뒤에는 사본과 대조한다.
- 시험 세션을 Orca 로 열면 cursor 는 `--yolo`, agy 는 `--dangerously-skip-permissions` 가 붙는다(Orca 가 붙인다) — 화면이 보통 세션과 다르다(cursor 의 `Run Everything`).
- tmux 로 낮은 창을 만들 때: `tmux -L sctest new-session -d -s sctest -x 90 -y 14 claude`, 대상은 `--tmux sctest:0.0 --tmux-socket sctest`. 화면도 포커스도 건드리지 않는다. 끝나면 `tmux -L sctest kill-server`.
- 새로 깐 앱은 SSH 에서 처음 띄울 수 없다(집 맥 2 실측: 프로세스가 시작 직전에서 멈춘다) — 사람이 그 맥의 화면에서 한 번 열어야 한다. 한 번 연 뒤로는 `open -a` · `open -na kitty --args …` 가 ssh 에서 된다.
- **집 맥 2 에서 터미널을 시험하는 법(2026-10-12)**: 디버그 빌드의 `slashcommand` 를 `/tmp` 에 복사해 ssh 에서 돌린다. 대상은 `--bundle <번들 id>`(그 앱이 맨 앞인 것처럼 — 단축키가 가는 길 그대로. `where` · `doctor` · `apply` · `effort` 모두). WezTerm 은 `wezterm cli spawn` · `activate-pane` · `send-text --no-paste`, kitty 는 `open -na kitty --args -o allow_remote_control=socket-only --listen-on unix:/tmp/…` 로 따로 띄워 `kitty @ --to … send-text` · `focus-tab` · `focus-window`. WezTerm 의 포커스 pane 은 WezTerm 이 맨 앞일 때만 탭 전환을 따라온다 — 먼저 `open -a WezTerm`.
- 리뷰어(pullfrog)는 «화면 밖의 것을 화면으로 읽어 입력을 허락하는가» 를 끝까지 판다(#27 에서 5번). 화면의 경계를 어림으로 정하는 코드는 «어느 쪽으로 틀려도 무엇이 일어나는가» 를 둘 다 적고, 입력을 허락하는 판정은 확실히 보이는 줄에서만 성립하게 짠다.
- **시험은 «실제 키» 로도 한다.** 오전까지의 실기는 명령줄(`--bundle`)로만 했고, 그 길은 프로세스를 매번 새로 띄운다. 오래 떠 있는 앱에서만 드러나는 것(자식이 끝난 것을 놓침)과 앱만 겪는 것(허용 창 · 알림 문구)은 설치본에 키를 넣어야 보였다(#31).
- **명령줄 프로그램은 맨 앞 앱이 바뀐 것을 모른다**: 런루프가 돌지 않으면 `NSWorkspace.shared.frontmostApplication` 이 처음 읽은 그대로다(6초 동안 그대로 — 실측). 다시 읽기 전에 런루프를 잠깐 돌린다(`AutomationConsent.frontBundleID`).
- **접근성 나무는 나무가 아닐 수 있다**(#33): 돌 때는 이미 본 요소(`CFEqual`) · 깊이 · 개수를 같이 막는다. 명령이 아무것도 찍지 않고 끝나면 종료 코드를 본다(139 = 죽었다) — `| head` 를 붙이면 코드가 가려진다. 충돌 기록은 `~/Library/Logs/DiagnosticReports/slashcommand*.ips`.
- `gh pr checks <번호> --watch` 는 PR 을 만든 직후에는 «no checks reported» 로 바로 끝난다 — 체크가 생길 때까지 기다린 뒤에 건다(`until gh pr checks N | grep -q pullfrog-approval; do sleep 20; done`).
- `run` 의 일꾼처럼 «나중에 다른 프로세스가 입력하는» 코드는 대상(터미널)만이 아니라 «그 세션» 의 신원(pid + 시작 시각)을 들고 간다 — 터미널 주소는 다른 세션이 다시 쓴다(#29 리뷰).
- ssh 에서 AppleScript 로 Ghostty · iTerm2 를 건드리면 «권한 없음»(-1743)으로 실패하면서 **그 앱을 띄워 버린다**(집 맥 2 에서 Ghostty 가 떴다 — 시작 시각을 확인하고 껐다).
- 시험용 에이전트를 `~/Downloads` · `~/Documents` · `~/Desktop` 에서 띄우지 않는다 — 그 터미널 앱이 처음이면 폴더 접근 허용 창이 그 맥의 화면에 뜨고 에이전트는 아무것도 그리지 않은 채 멈춘다. claude 의 «이 폴더를 믿습니까» 도 새 폴더(`/tmp/…`)에서 뜬다 — 이미 믿는 폴더(`~/Repos` 등)를 쓴다.
- kitty 의 창 안에서 도는 프로세스는 환경변수가 읽히지 않는다(kitty 가 셸을 `login` 으로 띄운다 — `ps eww` 로 0개). `kitty @ ls` 의 `env` 에는 그 창의 환경변수가 통째로 들어 있다 — 값을 출력하지 않는다.
- opencode 2 는 뒤에서 도는 서버 하나를 같이 쓴다. 따로 떨어진 시험 세션은 `env -u <키 변수들> XDG_DATA_HOME=… XDG_STATE_HOME=… opencode --standalone`(로그인 없는 «제공자 하나» 상태가 된다 — 셸에 `OPENROUTER_API_KEY` 같은 변수가 있으면 그 제공자가 잡히므로 뺀다). 상태 폴더가 다른 opencode 세션이 둘 떠 있으면 «누구의 기본값을 지킬지 모른다» 며 멈춘다(의도한 동작) — 한 번에 하나만 띄운다.
- opencode · cursor 의 대화상자를 손으로 열어 고르면 기본값 파일이 바뀐다(앱을 거치지 않으면 되돌려지지 않는다). 손으로 본 뒤에는 사본과 대조한다.
- **집 맥 2 의 codex 뒤 서버(app-server-daemon)**: 시험용 codex 를 띄우면 codex 가 뒤에서 도는 서버를 스스로 띄워 둔다(세션을 닫아도 남는다). 2026-10-12 06:20 에 뜬 그 서버가 07:11 에는 새 codex 세션마다 «Cannot use the background server … 1. Run without daemon this time / 2. Cancel» 창을 띄우게 했다(그 창에서는 «입력창이 안 보인다» 로 전환하지 않는다). 그 서버를 끝내자 새 세션이 정상으로 떴다(같은 판 0.162.0 / 서버 0.162.1 — 판 차이가 원인이라는 가설은 기각). 세션을 그냥 닫는 것(`kill-pane`) 한 번으로는 재현되지 않았다 — 원인은 모른다. 시험이 끝나면 내가 띄운 서버가 남았는지 보고(시작 시각으로 가린다) 끝낸다.
- 시험 전 사본과 다르다고 «내가 바꿨다» 가 아니다: 2026-10-12 집 맥의 `~/.codex/config.toml`(06:26, 다른 폴더의 trust 항목)과 `~/.cursor/cli-config.json`(06:35, 모델 키가 생김)이 달라져 있었는데 그 시각 이 작업은 집 맥 2 에서 돌고 있었고 집 맥에서 codex · cursor 를 띄운 적이 없다 — 다른 세션의 쓰기다. 되돌리지 않았다.
- 낮은 창을 만들려고 tmux 칸을 나누면(`split-window`) 23줄이 11줄 둘이 된다 — claude 의 선택창은 11줄에서 맨 아래 안내 줄이 잘린다(#25 에서 처리).
- codex 는 시작할 때 업데이트 창을 띄울 수 있다(`1. Update now` 에 커서). 그 창에서는 `doctor` 가 «input box not visible» 이라 전환하지 않는다. Esc 로 건너뛴다 — Enter 는 업데이트를 돌린다.
- 화면 표본은 `orca terminal read` 가 아니라 **`slashcommand doctor … --dump 파일.json`** 으로 뜬다(전자는 아래쪽 줄이 빠질 수 있다 — agy 에서 겪음). `doctor` 의 대상은 `--orca`·`--ghostty`·`--tmux`·`--kitty`·`--wezterm` 으로 직접 적거나 `--bundle <번들 id>`(그 앱이 맨 앞인 것처럼)로 정한다 — #25 부터 `where`·`doctor`·`apply`·`effort` 가 모두 같은 대상 옵션을 받는다.
- 화면을 눈으로 볼 때: `SlashCommand --snapshot 파일.png`(설정 창) · `--menu-text [번들 id]`(메뉴). 화면 녹화 권한이 필요 없다.
- **번역**: 문장을 바꾸거나 더하면 8개 언어 파일을 다 고쳐야 테스트가 통과한다. 테스트는 «빠진 문장 · 남는 문장 · 자리표 수» 만 본다 — 값이 둘 이상인 문장에서 어순이 영어와 달라지면 `%1$@`·`%2$@` 로 번호를 붙여야 하고, 그건 눈으로 봐야 한다(2026-10-11 아랍어에서 프리셋 번호와 에이전트가 뒤바뀐 것을 리뷰어가 잡았다).
- 기존 테스트는 한국어 번역표를 켜고 돈다(`KoreanMessagesTestCase`). 새 문장을 보는 테스트를 쓸 때 영어를 기대하면 실패한다 — `loc("…")` 로 비교하거나 영어 상태에서 도는 `L10nTests` 에 넣는다.
- 메뉴(주 스레드)에서 오래 걸릴 수 있는 것을 부르지 않는다: 자동화 권한 확인(`AEDeterminePermissionToAutomateTarget`)은 뒤에서 알아 둔 값을 본다.
- grok·cursor·agy·opencode 는 «이 세션만» 이 없다. 손으로 시험해도 기본값 파일이 바뀐다.
- cursor: 글자를 한 덩이로 보내면 붙여넣기로 보고 무시한다(한 글자씩). 편집 화면의 `◯ Fast` 는 Effort 가 아니다.
- 리뷰어의 지적은 «주장» 이다 — 코드나 실제 화면으로 재고 나서 고친다(판정 기록은 `docs/PLAN-generalization.md` 끝).
- 요한님이 뭔가를 시스템 설정에서 켜야 하면 글로 안내하지 말고 앱에 그 화면을 여는 버튼을 둔다(2026-10-08 요한님).
