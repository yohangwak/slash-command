# ModelSwitch

Ghostty·Orca 터미널에서 **⇧⌥1 … ⇧⌥9** 를 누르면, 맨 앞 세션이 claude 인지 codex 인지에 맞춰
그 번호 프리셋의 **모델 + effort** 로 바꾸는 맥 메뉴 막대 앱.

`/model`·`/effort` 를 매번 치는 대신 단축키 한 번. 대화 도중에도 되고, 쓰던 글은 그대로 남는다.

## 쓰기

| 무엇 | 어떻게 |
|---|---|
| 전환 | Ghostty 나 Orca 가 맨 앞일 때 `⇧⌥번호`(조합 키는 편집 화면에서 바꾼다). 화면 아래에 결과가 잠깐 뜬다 |
| 프리셋 편집 | 메뉴 막대 톱니 → 「프리셋 편집…」 (파일은 `~/.config/modelswitch/presets.json`) |
| 터미널에서 | `modelswitch list` · `modelswitch where` · `modelswitch doctor --screen` · `modelswitch apply 2` |
| 기록 | `~/Library/Logs/ModelSwitch/modelswitch.log` |

번호는 「의도」다 — 같은 번호가 claude 에서는 claude 모델, codex 에서는 codex 모델로 간다.
한쪽 설정이 없는 번호는 그 에이전트에서 아무것도 하지 않는다.

```json
{
  "version": 1,
  "keepDefaults": true,
  "modifiers": ["option", "shift"],
  "slots": [
    { "name": "기본",   "claude": { "model": "opus",   "effort": "high" }, "codex": { "model": "gpt-6-astra", "effort": "high" } },
    { "name": "가볍게", "claude": { "model": "sonnet", "effort": "high" }, "codex": { "model": "gpt-6.1-sol", "effort": "high" } },
    { "name": "최고",   "claude": { "model": "fable",  "effort": "high" } }
  ]
}
```

- claude `model` 은 `/model` 이 받는 값(`fable`·`opus`·`sonnet`·`haiku` 또는 전체 모델 id), `effort` 는 `low`·`medium`·`high`·`xhigh`·`max`.
- codex `model` 은 `/model` 선택창에 보이는 모델의 slug, `effort` 는 `low`·`medium`·`high`·`xhigh`.

## 설치

```sh
./scripts/build-app.sh --install   # ~/Applications/ModelSwitch.app 에 설치하고 실행, ~/.local/bin/modelswitch 링크
```

처음 한 번 허용할 것:

- **자동화**(ModelSwitch → Ghostty): Ghostty 에서 처음 누를 때 묻는다. 터미널에 명령을 입력하는 데 쓴다.
- **손쉬운 사용**(ModelSwitch): Ghostty 화면을 읽는 데 쓴다. Orca 만 쓰면 필요 없다.

## 어떻게 동작하나

1. **단축키** — Carbon 전역 핫키. 키 위치로 잡으므로 한글 입력 상태와 무관하다. Ghostty·Orca 가 맨 앞일 때만 등록해서 다른 앱에서는 그 조합이 원래대로 동작한다.
2. **대상 찾기**
   - Ghostty: AppleScript 로 맨 앞 터미널의 id·제목·폴더를 읽는다. 제목에 `claude`/`codex` 가 없으면 그 폴더에서 도는 에이전트 프로세스로 가린다.
   - Orca: 화면에 떠 있는 워크스페이스는 Orca 상태 DB(`profile-state.db` 의 `workspaceSession`)에서, 그 안의 활성 탭·터미널은 `orca terminal list --include-visual-layouts` 에서 읽는다. 에이전트 종류는 그 터미널에서 도는 프로세스로 가린다(목록의 `agentIdentity` 는 대기 중에 비어 온다).
3. **입력창 확인** — 화면을 읽어 에이전트의 입력창이 «보일 때만» 보낸다(아래 「안전」).
4. **전환**
   - claude: `Ctrl+S`(쓰던 글 보관) → `/model <모델>` → `Ctrl+S` → `/effort <단계>`.
   - codex: `/model` 선택창을 키로 조작하고 `s` 로 확정한다(이 세션에만 적용).
5. **기본값 되돌리기**(claude) — `/model`·`/effort` 는 새 세션 기본값(`~/.claude/settings.json`)까지 바꾼다. 전환 전 내용을 잡아 두었다가 기본값 항목만 되돌린다. 열려 있는 세션은 그대로다.

글자·키는 합성 키 입력이 아니라 터미널에 바이트로 직접 쓴다(Ghostty `perform action "text:…"`, Orca `terminal send`).

## 안전

- **입력창이 안 보이면 아무것도 보내지 않는다.** 권한 확인 창·승인 창·선택창이 떠 있을 때 Enter 를 보내면 그 창의 기본 선택지("Yes")가 눌린다. 판정은 「창이 없다」가 아니라 「입력창이 보인다」다(`Readiness.swift`, 실제 화면 표본으로 테스트).
- **화면을 못 읽으면 보내지 않는다.** 확인 없이 보내는 경로는 없다.
- codex 는 단계마다 화면에 기대한 창이 떴는지 확인하고, 아니면 멈춘다. 여러 줄 초안이 있으면 손대지 않는다.
- codex 의 effort 는 숫자 키로 고르지 않는다 — 숫자 키는 기본값까지 저장한다.

## 한계

- codex effort `max`·`ultra`(More reasoning 하위)와, effort 가 4단계뿐인 모델은 아직 지원하지 않는다.
- codex 선택창의 모델 순서는 `~/.codex/models_cache.json` 에서 계산한다. 10번째 이후 모델은 숫자 키로 고를 수 없다.
- Orca 의 「화면에 떠 있는 워크스페이스」는 공개 인터페이스가 아닌 상태 DB 에서 읽는다. Orca 업데이트로 형식이 바뀌면 추측하지 않고 실패한다.
- Orca 플로팅 터미널, Terminal.app·iTerm 등 다른 터미널은 지원하지 않는다.
- claude 전환 직후 약 2초 동안은 새 세션 기본값이 바뀐 상태다. 그 사이에 뜬 세션은 바뀐 기본값으로 시작한다.

## 개발

```sh
swift build && swift test          # 핵심 로직은 ModelSwitchCore, 테스트 표본은 Tests/ModelSwitchCoreTests/Fixtures
.build/debug/modelswitch plan 1 codex     # 보낼 키 순서만 출력
.build/debug/modelswitch apply 2 --orca <핸들> --agent claude   # 대상을 직접 지정(시험용)
```

구조: `ModelSwitchCore`(프리셋·감지·입력·판정·기본값 복원) · `modelswitch`(명령줄) · `ModelSwitchApp`(메뉴 막대·단축키·편집 화면).
