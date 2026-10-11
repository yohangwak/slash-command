# Slash Command — 할 일 · 이어받기

마지막 갱신: 2026-10-12 07:20 KST (10-11: 화면 개편 #16 · 9개 언어 #17 · `run` 확대 #18 · 확인한 판 #19 · 실기로 찾은 결함과 cursor `run` · 낮은 창 #21. 10-12: grok 1.0.50 #23 · opencode 2 #24 · WezTerm · kitty · tmux 단축키 #25 · 네 맥 설치). 이 파일은 main 에 있다.

## 새 대화에서 이렇게 말하면 이어진다

> slash-command repo 의 `TODO.md` 를 끝까지 읽고 이어서 진행해줘.

(비서 기록은 `ai-assistant` 의 `log/2026-10-10-*slashcommand*` · `log/2026-10-11-*slashcommand*`.)

## 지금 상태

- **main = `1d3020f`(PR #25, 2026-10-12).** 테스트 254개(Xcode 가 있는 맥에서 — 집 맥 2).
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
- **깔린 앱**: **네 맥 모두**(집 맥 = Mac Studio · 집 맥 2 = 옛 Mac mini · 사 맥 · 맥북) = main `1d3020f` 빌드(2026-10-12 07:10, 실행 파일 sha256 `aa546e87…`, `Apple Development` 서명, 로그인 항목 켬). 설치한 빌드로 다시 확인: 집 맥에서 grok(낮은 창 첫 화면 · 프리셋 · effort) · opencode 2(둘째 행 모델 · 프리셋 · effort), 집 맥 2 에서 WezTerm 의 codex(프리셋 2개 · effort 내림/올림) — 메뉴도 `Codex · WezTerm` 으로 뜬다.
- **집 맥에 깔린 에이전트·도구(2026-10-12 조회)**: claude 2.1.296 · codex 0.162.0 · cursor-agent 2026.10.01-e373342(로그인됨) · agy 1.3.3(로그인됨) · opencode 2.0.25(Homebrew, **OpenCode Go 로그인됨** — 제공자가 Go · Zen 둘) · grok 1.0.50(**로그인됨**) · tmux 3.8. opencode 2 는 처음 띄울 때 뒤에서 도는 서버(`opencode serve --service`)를 스스로 띄워 둔다(10-11 21:54 부터 떠 있다 — opencode 자신의 것이라 그대로 뒀다).
- **집 맥 2 의 터미널**: WezTerm · kitty · iTerm2(Homebrew cask) · tmux 3.7c. 요한님이 2026-10-12 05:46 에 그 화면에서 세 앱을 열어 줘서 그 뒤로 ssh 에서 다룰 수 있었다. 집 맥 2 의 에이전트: claude 2.1.295/2.1.296 · codex 0.162.0 · opencode 1.18.35(`~/.opencode/bin`) 등.
- **화면 언어**: 네 맥 모두 시스템 언어 1순위가 영어(`en-KR`)라 앱이 영어로 뜬다(맥북도 2026-10-11 22:59 에 확인). 한국어로 보려면 시스템 설정 → 일반 → 언어 및 지역 → 응용 프로그램에서 Slash Command 를 한국어로.
- **실기 확인**: 2026-10-11 집 맥 — claude 2.1.296 · codex 0.162.0 · cursor · antigravity. 2026-10-12 — grok 1.0.50(집 맥) · opencode 2.0.25(집 맥, 제공자 둘 / 격리 폴더로 제공자 하나) · opencode 1.18.35(집 맥 2) · WezTerm · kitty · 그 안의 tmux(집 맥 2, claude 2.1.295 · codex). 모두 따로 연 시험 세션에서, 시험한 에이전트의 기본값 파일은 시험 전 사본과 같거나 사본으로 되돌렸다(아래 「내가 바꿔 둔 것」).
- GitHub 저장소 `yohangwak/slash-command`. 자동 리뷰어(pullfrog)의 승인 체크(`pullfrog-approval`)가 통과해야 머지된다 — 우회 머지는 하지 않는다. 리뷰 1회 3~8분.
- **iTerm2 코드는 `yohangwak/agents` 브랜치(`a460a8f`)에 보관돼 있다** — main 에는 없다(아래 2번).

## 요한님 손이 필요한 것

1. **새 화면을 눈으로 한 번 봐 주기.** 메뉴와 설정 창은 그림으로 뽑아 확인했을 뿐 실제 화면에서 눌러 보지 못했다: 설정 창의 글 상자에서 ⌘V 가 되는지 · 프리셋 줄을 눌러 펼쳐지는지 · 저장 뒤 단축키가 그대로인지 · 알림이 뜨는 자리. WezTerm · kitty 에서 실제 단축키(⇧⌥번호)를 누르는 것도 — 내가 한 것은 `--bundle` 로 «그 앱이 맨 앞인 것처럼» 같은 길을 태운 것이다(키를 누르지는 못한다).
2. **손쉬운 사용 켜기**: 집 맥은 켜져 있다. 집 맥 2 와 맥북은 꺼져 있고(2026-10-11 23:00 관측), 사 맥은 확인하지 못했다. 설정 창 맨 위 「Permissions」 의 「Open Settings…」. (Ghostty 화면 읽기와 Orca 탭 줄에 쓴다 — WezTerm · kitty · tmux 에는 필요 없다.)
3. **iTerm2 를 하려면 집 맥 2 의 화면이 필요하다**(아래 1번): ssh 에서 띄운 프로세스는 iTerm2 에 AppleScript 를 보낼 수 없다(`Not authorized to send Apple events` — Ghostty 로 재 봤다). 앱 자신이 물어야 뜨는 «iTerm2 를 제어하도록 허용» 창과 손쉬운 사용 둘 다 사람이 그 화면에서 눌러야 한다. 맥북에는 그 허용이 이미 있을 수 있다(10-07 에 거기서 쟀다) — 거기서 해도 되면 그렇게 말해 주면 된다.
4. 집 맥 2 의 화면에 **«WezTerm 이 다운로드 폴더의 파일에 접근하려고 합니다» 창이 떠 있을 수 있다**(확인은 못 했다 — 시험용 claude 를 `~/Downloads` 에서 띄웠더니 아무것도 그리지 않고 멈췄고, 다른 폴더에서는 바로 떴다). 떠 있으면 «허용 안 함» 을 눌러도 된다.
5. 결정이 필요한 것: 라이선스 · Developer ID 서명/공증(공개 배포를 할지) · 번역을 원어민에게 보일지.
6. 시스템 설정의 손쉬운 사용 목록에 남은 옛 ModelSwitch 항목은 − 로 지워도 된다.

## 다음 할 일 (순서대로)

1. **iTerm2 를 별도 PR 로**(위 3번이 먼저 — 그 화면에서 허용을 눌러 줄 사람이 있어야 실기 확인이 된다): `origin/yohangwak/agents`(`a460a8f`)의 iTerm2 조각(`ITermIO` · `ITermBroadcast` · `Detector.iterm()` · `--iterm` · 테스트 · `Permissions.automatedTerminals` 의 iTerm2 줄)을 main 위로 다시 얹는다. 그 브랜치는 개명·영어 전환 전이다 — 이름을 `SlashCommand*` 로, 문구를 `loc("…")` 로(문장 10개 남짓 × 8개 언어). 남은 문제는 «입력 방송(Broadcast Input)»: 지금 코드는 메뉴 체크 표시를 접근성으로 읽고 켜져 있으면 보내지 않는다(확인과 쓰기가 따로다). 구조적 해법은 iTerm2 의 Python API(`Session.async_send_text(text, suppress_broadcast=True)`, 웹소켓 + protobuf, 설정에서 켜야 한다)다. tmux 의 같은 문제는 #25 에서 «확인과 쓰기를 tmux 의 한 명령으로» 풀었다 — iTerm2 에 그런 한 번의 호출이 있는지부터 본다. iTerm2 는 세션의 tty 를 주므로, 되면 그 안의 tmux 도 #25 의 길(`Detector.session`)로 바로 된다.
2. **Ghostty · Orca · 그 밖의 터미널 앱 안의 tmux**: 아직 단축키로 안 된다. Ghostty 는 탭의 tty 를 주지 않는다. tmux 의 포커스 표시(`client_flags` 의 `focused`)는 `focus-events on` 을 «켠 채로 붙은» 클라이언트에서는 앱·탭 전환을 따라오지만(실측), 켜기 전에 붙은 클라이언트는 뒤로 가도 계속 `focused` 다(실측, tmux 3.7c) — 그 표시만 믿으면 뒤에 있는 탭의 칸에 쓴다. 그래서 넣었다가 뺐다. 길 후보: ① Ghostty 가 읽어 주는 화면 글과 `tmux capture-pane` 을 대조해 «지금 보이는 것이 그 칸» 임을 확인 ② Orca 는 핸들의 프로세스에서 tmux 클라이언트를 찾으면 tty 가 나온다(#25 의 길 그대로) ③ Terminal.app 은 AppleScript 가 탭의 tty 를 준다(자동화 허용 필요).
3. **`run` 을 opencode 2 에**: 맨 위 명령에 `--model` 이 없다. `OPENCODE_CONFIG_CONTENT='{"model":"opencode-go/glm-5.3"}'` 로 열어 봤으나 기억해 둔 마지막 모델(`model.json` 의 `recent`)이 이겼다(2026-10-12 실측 — 그 길은 안 된다). `opencode run --model 제공자/모델#variant` 는 글을 보내는 비대화형이다. 남은 길: 세션을 연 뒤 그 세션에서 전환을 «이어서» 돌리기(연 터미널을 대상으로 — Orca 핸들 · tmux 칸은 환경변수로 안다).
4. **범용 목표의 나머지**(요한님: «누구나 유용하게 쓸 수 있게»): 화면을 못 읽는 터미널(Terminal.app · VS Code 등) · 서명/공증(Developer ID) · 라이선스 · 자동 업데이트 · CI(맥 러너를 쓰지 않는 조건에서 무엇을 돌릴지) · 번역 검수. 순서와 근거는 `docs/PLAN-generalization.md`.
5. **독립 검토에서 확인하지 못하고 남긴 것**: 알림(HUD)이 여러 모니터에서 터미널이 있는 화면에 뜨는지(`NSScreen.main`) · Ghostty 가 응답하지 않을 때 실제로 5초 뒤에 풀리는지 · 설정 창에서 저장하면 편집 화면이 모르는 키(나중 판이 쓴 것)가 사라진다(`version` 은 지킨다).
6. cursor 의 `Fast`: 프리셋에는 그 스위치가 없다. 단축키로 바꾸면 그 행에 기억된 값(이 맥에서는 켜짐)을 따르고, `run` 으로 열면 꺼진 id 를 고른다 — 두 길의 결과가 다르다. 프리셋에 넣을지는 쓰임을 보고.
7. 작은 것: grok · (집 맥 2 의) opencode 는 실행 파일 경로에 판이 없어 `doctor` 가 «running unknown» 이라 한다(설치된 판은 읽는다) · opencode 에서 variant 가 없는 모델(Big Pickle 등)에 effort 를 누르면 «variant 대화상자가 열리지 않았다» 로 4초 뒤 끝난다(바뀌는 것은 없다 — 문구와 시간을 다듬을 것) · 낮은 창의 claude 는 한 칸에 0.2초쯤 걸린다 · tmux 연결은 호출마다 프로세스를 띄워 한 번에 약 70ms 다(상주 연결로 줄일 수 있다) · kitty 를 둘 이상 띄웠을 때 맨 앞 것이 원격 제어 없이 뜬 것이면 «꺼져 있다» 고 한다(의도한 동작).

## 내가 바꿔 둔 것 (되돌릴 수 있게)

- **프리셋**(`~/.config/slashcommand/presets.json`): 2026-10-10 에 각 맥의 옛 ModelSwitch 프리셋을 옮긴 것 그대로다. 집 맥·집 맥 2 의 1~3번에는 grok·cursor·antigravity·opencode 설정이 들어 있다(2026-10-08 에 추가 — 빼려면 설정 창에서 그 에이전트 줄의 − 를 누른다).
- **깔린 앱**: 위 「지금 상태」. 그 전의 앱은 지웠다(되돌리려면 그 커밋을 다시 빌드 — 아침 것은 `2345c4e`).
- **빌드·설치 방법(지금 환경)**: 서명 인증서와 Xcode 는 집 맥 2 에 있다(사 맥·맥북은 확인하지 않았다). 집 맥(Studio)은 Command Line Tools 뿐이라 `swift build` 는 되지만 `swift test` 는 `XCTest` 가 없어 실패하고 서명은 임시(ad-hoc)가 된다. 그래서 테스트와 서명 빌드는 집 맥 2 의 임시 폴더에서 한다. **SSH 세션에서는 `codesign` 이 `errSecInternalComponent` 로 실패한다**(로그인 키체인이 잠겨 있다) — `scripts/build-app.sh` 를 로그인 세션의 일회성 launchd 작업(`launchctl bootstrap gui/<uid>`)으로 돌린 뒤 작업과 폴더를 지운다. 다른 맥에는 `tar -C dist -cf - "Slash Command.app" | ssh <맥> 'tar -C ~/Applications -xf -'`(`scp -r` 은 조용히 실패한 적이 있다). 집 맥에 Xcode 와 인증서를 두면 이 우회가 필요 없다(요한님 손).
- **시험 세션**: 2026-10-11·12 에 연 시험 터미널(Orca 의 `SC-TEST…`, 집 맥의 tmux `-L sctest`·`sctest2`, 집 맥 2 의 tmux `-L scfront` · 따로 띄운 kitty · WezTerm 의 탭)은 모두 닫았다. codex · agy 는 시험 세션을 열 때 기본값 파일에 그 폴더의 trust 항목을 넣는다 — 시험 전 사본으로 되돌렸다. cursor 의 `cli-config.json` 도 시험 전 사본으로(모델 키가 없는 상태). opencode 의 `model.json` 은 시험 전에 없던 파일이라 지웠다. grok 의 `config.toml` 은 «처음 띄운 뒤의 상태»(grok 이 스스로 쓴 `[marketplace]` · `[ui]`, `[models]` 없음)로 뒀다.
- **집 맥에 깐 것**: grok 1.0.50(`~/.grok`, `~/.local/bin/grok` 링크 — 설치 스크립트가 `.zshrc` 를 고치지 않게 `SHELL=/bin/sh` 로 돌렸고, 같이 생긴 `~/.local/bin/agent` 링크는 지웠다) · tmux(`brew uninstall tmux` 로 지운다). 집 맥 2: `brew uninstall --cask wezterm kitty iterm2` · `brew uninstall tmux`. 세 앱의 격리 표시(`com.apple.quarantine`)는 공증을 확인한 뒤 지웠다. 집 맥 2 의 kitty 설정은 건드리지 않았다(원격 제어는 시험할 때만 `--listen-on` 인자로 따로 띄웠다).
- 맥북: Homebrew 로 깐 tmux·kitty·WezTerm·iTerm2 는 요한님 뜻대로 남겨 뒀다(2026-10-07). iTerm2 에 방송(Broadcast Input)을 켠 두 칸 창이 열려 있을 수 있다.

## 알아 둘 함정 (다시 밟지 않게)

- 시험은 반드시 따로 연 시험 세션에서. 시험 전에 각 에이전트의 기본값 파일을 «사본» 으로 남기고(해시만 남기면 달라졌을 때 대조할 수 없다) 끝나면 대조한다: claude `~/.claude/settings.json` · codex `~/.codex/config.toml` · grok `~/.grok/config.toml` · cursor `~/.cursor/cli-config.json`(인증 정보가 들어 있다 — 내용을 출력하지 않는다) · agy `~/.gemini/antigravity-cli/settings.json` · opencode `~/.local/state/opencode/model.json`.
- 🔴 **대상(`--orca <핸들> --agent …`)은 명령에 글자 그대로 쓴다.** zsh 에서 `$T` 처럼 변수에 묶어 넘기면 한 덩이 인자가 되어 대상 지정이 통째로 빠지고, 그러면 명령은 «맨 앞 세션»(요한님이 쓰고 있는 세션)을 대상으로 삼는다. 2026-10-11 에 그렇게 넘겼다 — 그때는 `apply 2` 도 한 덩이라 사용법만 찍히고 아무것도 보내지 않았다.
- 🔴 **cursor 는 모델 목록을 «여는 것만으로» 기본값 파일을 쓴다**(2026-10-11 실측: 목록이 열린 0.2초 뒤 그 세션의 지금 모델이 파일에 적혔다). 시험 세션에서 손으로 `/model` 을 열었다 닫으면(앱을 거치지 않으면) 그 값이 기본값으로 남는다 — 그렇게 남겼다가 사본으로 되돌렸다. 손으로 연 뒤에는 사본과 대조한다.
- 시험 세션을 Orca 로 열면 cursor 는 `--yolo`, agy 는 `--dangerously-skip-permissions` 가 붙는다(Orca 가 붙인다) — 화면이 보통 세션과 다르다(cursor 의 `Run Everything`).
- tmux 로 낮은 창을 만들 때: `tmux -L sctest new-session -d -s sctest -x 90 -y 14 claude`, 대상은 `--tmux sctest:0.0 --tmux-socket sctest`. 화면도 포커스도 건드리지 않는다. 끝나면 `tmux -L sctest kill-server`.
- 새로 깐 앱은 SSH 에서 처음 띄울 수 없다(집 맥 2 실측: 프로세스가 시작 직전에서 멈춘다) — 사람이 그 맥의 화면에서 한 번 열어야 한다. 한 번 연 뒤로는 `open -a` · `open -na kitty --args …` 가 ssh 에서 된다.
- **집 맥 2 에서 터미널을 시험하는 법(2026-10-12)**: 디버그 빌드의 `slashcommand` 를 `/tmp` 에 복사해 ssh 에서 돌린다. 대상은 `--bundle <번들 id>`(그 앱이 맨 앞인 것처럼 — 단축키가 가는 길 그대로. `where` · `doctor` · `apply` · `effort` 모두). WezTerm 은 `wezterm cli spawn` · `activate-pane` · `send-text --no-paste`, kitty 는 `open -na kitty --args -o allow_remote_control=socket-only --listen-on unix:/tmp/…` 로 따로 띄워 `kitty @ --to … send-text` · `focus-tab` · `focus-window`. WezTerm 의 포커스 pane 은 WezTerm 이 맨 앞일 때만 탭 전환을 따라온다 — 먼저 `open -a WezTerm`.
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
