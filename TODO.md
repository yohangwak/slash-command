# ModelSwitch — 할 일 · 이어받기

마지막 갱신: 2026-10-08 07:45 KST (세션 마무리). 이 파일은 `yohangwak/core` 브랜치(PR #10)에 있다 — main 에는 PR #10 이 머지돼야 들어간다.

## 새 대화에서 이렇게 말하면 이어진다

> modelswitch repo 의 `yohangwak/core` 브랜치에 있는 `TODO.md` 를 끝까지 읽고 이어서 진행해줘. 먼저 PR #10 의 리뷰 결과부터 확인해.

(워크스페이스를 새로 만들었으면 `git fetch && git switch yohangwak/core` 부터. 비서 기록은 `ai-assistant` 의 `log/2026-10-08-0745-modelswitch-session-close-*.md`.)

## 지금 상태

- **main = `851f3fa`(PR #7).** 그 뒤의 일은 전부 «아직 머지 안 됨».
- 머지를 막는 것: 이 repo 는 자동 리뷰어(pullfrog)의 승인 체크(`pullfrog-approval`)가 통과해야 머지된다. 관리자 권한 우회 머지는 자동 승인 도구가 막았고, 요한님은 «리뷰 승인 없이 머지» 를 명시적으로 허락한 적이 없다(B안 = 정상 리뷰로 머지 를 골랐다).

| PR | 브랜치 | 내용 | 상태 |
|---|---|---|---|
| **#10** | `yohangwak/core` | Orca 보이는 탭 수정 · 에이전트 4종(grok·cursor-agent·antigravity·opencode) · 권한 상자(설정 화면 바로 열기) — **iTerm2 제외** | 리뷰 3차 대기(마지막 커밋에서 남은 지적 1건을 고쳐 올림). **다음 대화의 첫 일: 결과 확인 → 통과면 머지, 지적이 있으면 «재서» 고친다** |
| #8 | `yohangwak/initial` | iTerm2 + Orca 수정(옛 묶음) | #10 이 머지되면 닫는다(대체됨) |
| #9 | `yohangwak/agents` | 에이전트 4종 + iTerm2 포함 전체(#8 위에 쌓음) | #10 이 머지되면 닫는다. **이 브랜치가 iTerm2 코드의 보관처다**(아래 3번) |

## 요한님 손이 필요한 것

1. **집 맥: ModelSwitch 에 손쉬운 사용(Accessibility) 켜기.** 메뉴 막대 아이콘 → 「프리셋·권한…」 → 맨 위 「권한」 상자의 「설정 열기…」 → 열린 목록에서 ModelSwitch 스위치 켜기. **이걸 켜야 Orca 의 «탭 옮긴 직후» 수정이 단축키에서 작동한다**(2026-10-08 확인: 꺼져 있었다. 꺼져 있으면 옛 방식 = 1~2.5초 지연).
2. 켠 뒤 확인: Orca 에서 탭을 «클릭» 으로 옮기고 바로 단축키 → 알림에 뜨는 대상이 방금 옮긴 탭인지. (내 시험은 CLI 로 탭을 바꾼 것 7/7 — 클릭 경로는 미확인.)
3. 새 에이전트 4종을 단축키로 써 보기(집 맥 프리셋 1~3번에 설정을 넣어 뒀다 — 아래 「내가 바꿔 둔 것」).
4. (iTerm2 를 계속할 거면) 맥북에서도 같은 권한 켜기. 맥북에는 아직 「권한」 상자가 없는 옛 빌드라, 다음 대화에서 새 빌드를 깔고 나서.

## 다음 할 일 (순서대로)

1. **PR #10 머지** → 세 맥에 main 빌드 설치(`./scripts/build-app.sh --install`, 다른 맥은 `tar -C dist -cf - ModelSwitch.app | ssh <맥> 'tar -C ~/Applications -xf -'` — `scp -r` 은 조용히 실패한 적이 있다) → #8·#9 닫기.
2. **실기 재확인(이번에 못 한 것)**: 2026-10-08 의 마지막 수정들(기본값 파일 없음/읽지 못함 처리 · opencode 상태 폴더 찾기 · 암묵 Default)은 단위 테스트만 통과했고 실제 터미널에서는 못 돌렸다 — Orca 가 1.4.222 로 다시 시작된 뒤 시험 터미널 화면이 10줄 안팎으로 깨져 읽혔다(원인 미확인. 후보: 다시 시작한 뒤 한 번도 띄우지 않은 탭). 그 탭들을 한 번 띄운 뒤 `modelswitch doctor --orca <핸들> --agent <에이전트> --screen` 으로 «입력창 보임» 인지 보고 시험한다.
3. **iTerm2 를 별도 PR 로**: `yohangwak/agents` 에서 iTerm2 조각(`ITermIO`·`ITermBroadcast`·`Detector.iterm()`·`--iterm`·테스트·`Permissions.automatedTerminals` 의 iTerm2 줄)을 main 위로 다시 얹는다. 남은 문제는 «입력 방송(Broadcast Input)» — 켜져 있으면 다른 칸에도 입력이 간다(맥북 실측). 지금 방어(맨 앞 창 확인 → 메뉴 읽기 → 다시 확인)는 리뷰어가 «최선의 노력일 뿐» 이라며 승인하지 않았다. 구조적 해법 후보: iTerm2 Python API 의 `suppress_broadcast`(설정·클라이언트 필요 — 미조사). 요한님 결정이 필요하면 선택지로 올린다.
4. **설정 창 다듬기**: 에이전트가 6개가 되어 프리셋 한 줄이 길다(창 높이 838, 프리셋 1개만 보임). 쓰는 에이전트만 보이고 「추가」 로 늘리는 꼴로.
5. **opencode**: 즐겨찾기한 비슷한 이름이 맨 위에 오면 고르지 않고 멈춘다(`GLM-5.3` 을 찾는데 `GLM-5.3-Flash` 가 맨 위). 목록 커서가 글자로 안 보여서다 — 아래로 내려가 고른 뒤 모델 줄로 확인하는 방법을 재 볼 것.
6. **`run`(새 세션 열기)**: cursor·agy·opencode 는 `--model` 이 받는 id 가 화면 이름과 달라 막아 뒀다. 각 CLI 의 `models` 출력으로 이름→id 를 풀 수 있는지.
7. **범용 목표의 나머지**(요한님: «누구나 유용하게 쓸 수 있게»): 화면을 못 읽는 터미널(Terminal.app·VS Code 등)을 어떻게 할지 · tmux·kitty·WezTerm 에 단축키 붙이기 · 문구를 영어 기준으로(영어+한국어) · 서명/공증(Developer ID)·라이선스·자동 업데이트 · CI. 순서와 근거는 `docs/PLAN-generalization.md`.
8. 작은 창에서 claude 가 명령 방식으로 가는 것(선택창에 모델 행이 다 안 보일 때 기본값을 잠깐 바꿨다 되돌림) — 범용이면 더 안전한 길을 찾을 것.

## 내가 바꿔 둔 것 (되돌릴 수 있게)

- **집 맥 프리셋**(`~/.config/modelswitch/presets.json`): 1~3번에 grok·cursor·antigravity·opencode 설정을 추가했다(claude·codex 값은 그대로). 원래는 claude·codex 뿐이었다 — 빼려면 그 키들만 지우면 된다.
- **집 맥에 깔린 앱**: PR #10 의 마지막 커밋 빌드(iTerm2 없음). 사 맥은 main(PR #7) 빌드, 맥북은 2026-10-07 의 중간 빌드(iTerm2 포함, 권한 상자 없음).
- **시험 터미널**(요한님이 연 것): cursor 세션이 Grok 4.7 **Medium** 으로 남았다(원래 High). 나머지는 원래 모델. 각 에이전트의 기본값 파일은 시험 전과 같다(해시 확인).
- 맥북: Homebrew 로 깐 tmux·kitty·WezTerm·iTerm2 는 요한님 뜻대로 남겨 뒀다. iTerm2 에 방송(Broadcast Input)을 켠 두 칸 창이 열려 있을 수 있다.

## 알아 둘 함정 (다시 밟지 않게)

- 시험은 반드시 따로 연 시험 세션에서. 시험 전에 각 에이전트의 기본값 파일을 «사본» 으로 남기고(해시만 남기면 달라졌을 때 대조할 수 없다) 끝나면 대조한다: claude `~/.claude/settings.json` · codex `~/.codex/config.toml` · grok `~/.grok/config.toml` · cursor `~/.cursor/cli-config.json`(인증 정보가 들어 있다 — 내용을 출력하지 않는다) · agy `~/.gemini/antigravity-cli/settings.json` · opencode `~/.local/state/opencode/model.json`.
- 화면 표본은 `orca terminal read` 가 아니라 **`modelswitch doctor … --dump 파일.json`** 으로 뜬다(전자는 아래쪽 줄이 빠질 수 있다 — agy 에서 겪음).
- grok·cursor·agy·opencode 는 «이 세션만» 이 없다. 손으로 시험해도 기본값 파일이 바뀐다.
- cursor: 글자를 한 덩이로 보내면 붙여넣기로 보고 무시한다(한 글자씩). 편집 화면의 `◯ Fast` 는 Effort 가 아니다.
- 리뷰어의 지적은 «주장» 이다 — 코드나 실제 화면으로 재고 나서 고친다(판정 기록은 `docs/PLAN-generalization.md` 끝).
- 요한님이 뭔가를 시스템 설정에서 켜야 하면 글로 안내하지 말고 앱에 그 화면을 여는 버튼을 둔다(2026-10-08 요한님).
