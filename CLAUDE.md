# Slash Command: notes for coding agents

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
