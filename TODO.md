# Slash Command — 할 일 · 이어받기

마지막 갱신: 2026-10-10 07:45 KST (개명 PR #12 머지와 네 맥 재설치까지). 이 파일은 main 에 있다.

## 새 대화에서 이렇게 말하면 이어진다

> slash-command repo 의 `TODO.md` 를 끝까지 읽고 이어서 진행해줘.

(비서 기록은 `ai-assistant` 의 `log/2026-10-08-0745-modelswitch-session-close-*.md` · `log/2026-10-10-0715-modelswitch-studio-install-*.md` 와 그 뒤의 개명 기록.)

## 지금 상태

- **main = `14815d5`(PR #12, 2026-10-10 머지) — ModelSwitch 를 Slash Command 로 개명**(요한님 결정: 지금은 모델 전환만 하지만 다른 슬래시 명령으로 넓힐 자리를 둔다). 기능은 PR #10(`19e9c87`) 그대로다. 테스트 190개.
  - 앱 `Slash Command.app` · 번들 id `com.yohangwak.slashcommand` · 명령 `slashcommand` · 설정 `~/.config/slashcommand/presets.json` · 기록 `~/Library/Logs/SlashCommand/slashcommand.log`.
  - **네 맥(집 맥 = Mac Studio · 집 맥 2 = 옛 Mac mini · 사 맥 · 맥북) 모두 이 빌드가 깔려 실행 중이다**(2026-10-10 07:38~07:39, 실행 파일 sha256 `1677cd0f…`, `Apple Development` 서명, 로그인 항목 켬). 옛 `ModelSwitch.app` 과 `modelswitch` 링크는 지웠다.
  - 아래 항목에서 2026-10-08 까지의 «집 맥» 은 옛 Mac mini(지금 «집 맥 2»)다.
- **GitHub 저장소 이름은 아직 `yohangwak/modelswitch`** 다(로컬 폴더만 `slash-command`). 바꿀지는 요한님 결정 — 바꾸면 각 맥 클론의 remote 와 리뷰어(pullfrog) 연결을 함께 확인한다.
- 이 repo 는 자동 리뷰어(pullfrog)의 승인 체크(`pullfrog-approval`)가 통과해야 머지된다. 우회 머지는 하지 않는다(요한님이 «리뷰 승인 없이 머지» 를 허락한 적 없음). 리뷰 1회에 5~16분.
- PR #8·#9 는 #10 으로 대체되어 닫았다. **iTerm2 코드는 `yohangwak/agents` 브랜치(`a460a8f`)에 보관돼 있다** — main 에는 없다(아래 「다음 할 일」 2번).

## 요한님 손이 필요한 것

1. **네 맥 모두: Slash Command 에 손쉬운 사용(Accessibility) 켜기.** 번들 id 가 바뀌어 옛 허용은 이어지지 않는다(2026-10-10 07:40 관측 — 집 맥·집 맥 2·맥북: 꺼짐, 사 맥: 확인 못 함. 집 맥 2 는 ModelSwitch 때 켜져 있었다). 메뉴 막대 아이콘 → 「프리셋·권한…」 → 맨 위 「권한」 상자의 「설정 열기…」 → 열린 목록에서 Slash Command 스위치 켜기. Ghostty 는 이 권한이 없으면 단축키가 동작하지 않고, Orca 는 «탭 옮긴 직후» 수정이 작동하지 않는다. 켠 뒤 Ghostty 에서 처음 단축키를 누르면 자동화(Slash Command → Ghostty) 허용 창이 한 번 뜬다. 목록에 남은 ModelSwitch 항목은 지워도 된다.
2. 켠 뒤 확인: Orca 에서 탭을 «클릭» 으로 옮기고 바로 단축키 → 알림에 뜨는 대상이 방금 옮긴 탭인지. (내 시험은 CLI 로 탭을 바꾼 것 7/7 — 클릭 경로는 미확인.) **개명한 빌드로는 실제 전환을 아직 한 번도 보내지 않았다**(설치·실행·프리셋 읽기까지만 확인).
3. 새 에이전트 4종을 단축키로 써 보기(집 맥·집 맥 2 프리셋 1~3번에 설정을 넣어 뒀다 — 아래 「내가 바꿔 둔 것」. 집 맥에는 grok·cursor-agent·opencode 가 깔려 있지 않다).

## 다음 할 일 (순서대로)

1. **실기 재확인(이번에 못 한 것)**: 2026-10-08 의 마지막 수정들(기본값 파일 없음/읽지 못함 처리 · opencode 상태 폴더 찾기 · 암묵 Default)은 단위 테스트만 통과했고 실제 터미널에서는 못 돌렸다 — Orca 가 1.4.222 로 다시 시작된 뒤 시험 터미널 화면이 10줄 안팎으로 깨져 읽혔다(원인 미확인. 후보: 다시 시작한 뒤 한 번도 띄우지 않은 탭). 그 탭들을 한 번 띄운 뒤 `slashcommand doctor --orca <핸들> --agent <에이전트> --screen` 으로 «입력창 보임» 인지 보고 시험한다.
2. **iTerm2 를 별도 PR 로**: `yohangwak/agents` 에서 iTerm2 조각(그 브랜치는 개명 전이라 `ModelSwitch*` 이름이다 — 얹을 때 `SlashCommand*` 로 바꾼다. `ITermIO`·`ITermBroadcast`·`Detector.iterm()`·`--iterm`·테스트·`Permissions.automatedTerminals` 의 iTerm2 줄)을 main 위로 다시 얹는다. 남은 문제는 «입력 방송(Broadcast Input)» — 켜져 있으면 다른 칸에도 입력이 간다(맥북 실측). 지금 방어(맨 앞 창 확인 → 메뉴 읽기 → 다시 확인)는 리뷰어가 «최선의 노력일 뿐» 이라며 승인하지 않았다. 구조적 해법 후보: iTerm2 Python API 의 `suppress_broadcast`(설정·클라이언트 필요 — 미조사). 요한님 결정이 필요하면 선택지로 올린다.
3. **설정 창 다듬기**: 에이전트가 6개가 되어 프리셋 한 줄이 길다(창 높이 838, 프리셋 1개만 보임). 쓰는 에이전트만 보이고 「추가」 로 늘리는 꼴로.
4. **opencode**: 즐겨찾기한 비슷한 이름이 맨 위에 오면 고르지 않고 멈춘다(`GLM-5.3` 을 찾는데 `GLM-5.3-Flash` 가 맨 위). 목록 커서가 글자로 안 보여서다 — 아래로 내려가 고른 뒤 모델 줄로 확인하는 방법을 재 볼 것.
5. **`run`(새 세션 열기)**: cursor·agy·opencode 는 `--model` 이 받는 id 가 화면 이름과 달라 막아 뒀다. 각 CLI 의 `models` 출력으로 이름→id 를 풀 수 있는지.
6. **범용 목표의 나머지**(요한님: «누구나 유용하게 쓸 수 있게»): 화면을 못 읽는 터미널(Terminal.app·VS Code 등)을 어떻게 할지 · tmux·kitty·WezTerm 에 단축키 붙이기 · 문구를 영어 기준으로(영어+한국어) · 서명/공증(Developer ID)·라이선스·자동 업데이트 · CI. 순서와 근거는 `docs/PLAN-generalization.md`.
7. 작은 창에서 claude 가 명령 방식으로 가는 것(선택창에 모델 행이 다 안 보일 때 기본값을 잠깐 바꿨다 되돌림) — 범용이면 더 안전한 길을 찾을 것.

## 내가 바꿔 둔 것 (되돌릴 수 있게)

- **프리셋**(`~/.config/slashcommand/presets.json`): 각 맥의 옛 `~/.config/modelswitch/presets.json` 을 그대로 복사한 것이다(옛 파일과 옛 기록 `~/Library/Logs/ModelSwitch/` 는 남겨 뒀다 — 지워도 된다). 집 맥(Studio)은 집 맥 2 의 것을 가져왔다. 집 맥·집 맥 2 의 1~3번에는 grok·cursor·antigravity·opencode 설정이 들어 있다(2026-10-08 에 추가, 원래는 claude·codex 뿐 — 빼려면 그 키들만 지운다).
- **깔린 앱**: 네 맥 모두 main(`14815d5`) 빌드. iTerm2 단축키는 없다.
- **빌드·설치 방법(지금 환경)**: 서명 인증서와 Xcode 는 집 맥 2 에만 있다. 집 맥(Studio)은 Command Line Tools 뿐이라 `swift build` 는 되지만 `swift test` 는 `XCTest` 가 없어 실패하고, 서명은 임시(ad-hoc)가 된다(빌드마다 권한을 다시 묻는다). 그래서 테스트와 서명 빌드는 집 맥 2 의 임시 폴더에서 했다. **SSH 세션에서는 `codesign` 이 `errSecInternalComponent` 로 실패한다**(로그인 키체인이 잠겨 있다) — `scripts/build-app.sh` 를 로그인 세션의 일회성 launchd 작업(`launchctl bootstrap gui/<uid>`)으로 돌린 뒤 작업과 폴더를 지웠다. 다른 맥에는 `tar -C dist -cf - "Slash Command.app" | ssh <맥> 'tar -C ~/Applications -xf -'`(`scp -r` 은 조용히 실패한 적이 있다). 집 맥에 Xcode 와 인증서를 두면 이 우회가 필요 없다(요한님 손).
- **시험 터미널**(요한님이 연 것): cursor 세션이 Grok 4.7 **Medium** 으로 남았다(원래 High). 나머지는 원래 모델. 각 에이전트의 기본값 파일은 시험 전과 같다(해시 확인).
- 맥북: Homebrew 로 깐 tmux·kitty·WezTerm·iTerm2 는 요한님 뜻대로 남겨 뒀다. iTerm2 에 방송(Broadcast Input)을 켠 두 칸 창이 열려 있을 수 있다.

## 알아 둘 함정 (다시 밟지 않게)

- 시험은 반드시 따로 연 시험 세션에서. 시험 전에 각 에이전트의 기본값 파일을 «사본» 으로 남기고(해시만 남기면 달라졌을 때 대조할 수 없다) 끝나면 대조한다: claude `~/.claude/settings.json` · codex `~/.codex/config.toml` · grok `~/.grok/config.toml` · cursor `~/.cursor/cli-config.json`(인증 정보가 들어 있다 — 내용을 출력하지 않는다) · agy `~/.gemini/antigravity-cli/settings.json` · opencode `~/.local/state/opencode/model.json`.
- 화면 표본은 `orca terminal read` 가 아니라 **`slashcommand doctor … --dump 파일.json`** 으로 뜬다(전자는 아래쪽 줄이 빠질 수 있다 — agy 에서 겪음).
- grok·cursor·agy·opencode 는 «이 세션만» 이 없다. 손으로 시험해도 기본값 파일이 바뀐다.
- cursor: 글자를 한 덩이로 보내면 붙여넣기로 보고 무시한다(한 글자씩). 편집 화면의 `◯ Fast` 는 Effort 가 아니다.
- 리뷰어의 지적은 «주장» 이다 — 코드나 실제 화면으로 재고 나서 고친다(판정 기록은 `docs/PLAN-generalization.md` 끝).
- 요한님이 뭔가를 시스템 설정에서 켜야 하면 글로 안내하지 말고 앱에 그 화면을 여는 버튼을 둔다(2026-10-08 요한님).
