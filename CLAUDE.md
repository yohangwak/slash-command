# Slash Command: notes for coding agents

> 📏 **이 파일은 모든 AI 대화에 통째로 실린다 — 본문엔 모든 작업에 필요한 규칙·판정식·한 줄 이유와 «작업 → 문서» 목록만 둔다.** 경위·실측·날짜별 정정은 `docs/claude/<주제>.md`(원문은 `docs/claude/history/`), 폴더 한정 규칙은 그 폴더 `CLAUDE.md`, 변경 이력은 PR 본문 — 날짜 절을 쌓지 않는다. 32,000바이트를 넘기며 커지는 커밋은 막힌다(맥 전역 pre-commit 훅).

A macOS menu bar app that switches the model and effort of the coding agent in the frontmost terminal. Read [docs/how-it-works.md](docs/how-it-works.md) and [docs/CONTRACT.md](docs/CONTRACT.md) before changing how keys are sent.

## Commands

```sh
swift build
swift test                        # needs Xcode (XCTest); the Command Line Tools alone cannot run it
./scripts/build-app.sh            # dist/Slash Command.app
```

There is no macOS CI. Tests run locally.

## Rules

- The safety rules in [docs/safety.md](docs/safety.md) are the product. Do not add a path that sends keys without seeing the agent's input box, that treats an unreadable screen as a clear one, that logs screen text, or that uses the network.
- Changing a user-facing sentence means updating all nine `Resources/*.lproj/Localizable.strings`. A test fails until they match.
- Test against real agents only in a separately opened test session. Copy each agent's defaults file first and compare afterwards. If it differs, restore only the key the test changed, never the whole file. Details: [docs/development.md](docs/development.md#rules-for-testing-against-real-agents).
- Never print `~/.cursor/cli-config.json` (credentials), the output of `kitty @ ls` (each window's environment), or run `opencode auth export`.
- User-facing docs are in English. `README.<language>.md` are translations of `README.md`; when the README changes, update them in the same change.
