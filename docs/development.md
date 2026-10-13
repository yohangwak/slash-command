# Development

## Build and test

```sh
swift build
swift test                                  # needs Xcode; the Command Line Tools alone have no XCTest
./scripts/build-app.sh                      # dist/Slash Command.app
./scripts/build-app.sh --install            # also copies it to ~/Applications and restarts it
```

The package has three targets: `SlashCommandCore` (all logic), `slashcommand` (command line tool) and `SlashCommandApp` (menu bar app). Tests live in `Tests/SlashCommandCoreTests`. Screen samples taken from real sessions are in `Fixtures`, and the pickers are imitated by `FakeClaude` and `FakePicker` inside the tests.

There is no macOS CI. Run `swift test` locally before opening a pull request.

## Trying a change

```sh
.build/debug/slashcommand plan 1 codex                                   # print the steps; runs nothing
.build/debug/slashcommand doctor --screen                                # what the app sees; sends nothing
.build/debug/slashcommand apply 2 --orca <handle> --agent claude --trace # name the target yourself
SLASHCOMMAND_CONFIG=/path/presets.json .build/debug/slashcommand list    # use another presets file
SLASHCOMMAND_SCREEN_LAG_MS=520 .build/debug/slashcommand apply 1 --orca <handle> --agent claude   # take the Ghostty path in another terminal
```

### Rules for testing against real agents

These exist because each of them has gone wrong once.

- **Use a separate test session.** Never send test input to a session doing real work.
- **Read the screen before sending anything** to the test session.
- **Copy each agent's defaults file before the test and compare it afterwards.** A hash alone cannot tell you what changed. The files: `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.grok/config.toml`, `~/.cursor/cli-config.json` (it holds credentials, so never print it), `~/.gemini/antigravity-cli/settings.json`, `~/.local/state/opencode/model.json`.
- **If a file differs, restore only the key your test changed.** Other sessions write these files too, and so does the user.
- **Write the target on the command line literally.** In zsh, `$T` holding `--orca <handle> --agent claude` is passed as one argument. The target is then dropped and the command addresses the frontmost session.
- **Cursor writes its defaults file as soon as the model list opens.** Opening `/model` by hand in a test session leaves that model as the default.
- A target named on the command line skips detection. Check detection separately with `where` and `doctor`.
- A low window for testing: `tmux -L sctest new-session -d -s sctest -x 90 -y 14 claude`, then `--tmux sctest:0.0 --tmux-socket sctest`. It touches neither the screen nor the focus. Finish with `tmux -L sctest kill-server`.

### Seeing the interface without Screen Recording permission

```sh
SlashCommandApp --snapshot out.png [--dark] [--collapsed] [--height N]   # the Settings window as an image
SlashCommandApp --menu-text [bundle id]                                  # the menu as text, as if that app were in front
```

Prefix `SLASHCOMMAND_L10N_DIR=$PWD/Resources SLASHCOMMAND_LANG=ko` to see another language.

To ask the installed app, not your terminal, about its own Automation permission:

```sh
open -n -W -a "Slash Command" --stdout /tmp/status.txt --args --automation-status com.mitchellh.ghostty
# 0 allowed · -1743 denied · -1744 not asked yet
```

## Adding support for a new agent version

1. Run `slashcommand doctor --screen` in a session of that version.
2. Follow the checking steps in [CONTRACT.md](CONTRACT.md#4-checking-a-new-version-or-a-new-terminal).
3. If the screen wording changed, add a screen sample to the tests first, then change the reader.
4. Add the version to `AgentVersions.tested` and to [Agents](agents.md#versions).

## Languages

English is the base. The English sentence in the code is the key: `loc("Quit Slash Command")`. Translations are in `Resources/<language>.lproj/Localizable.strings`, and `build-app.sh` copies them into the app bundle. macOS picks among the languages the bundle contains, following the user's language order.

- Placeholders are `%@` (in order) and `%1$@` (numbered, for languages with a different word order).
- A test checks every language against the sentences in the code and compares the placeholders. Change or add a sentence and the test fails until every translation is updated.
- Not translated: the agents' own screen text (`Select model`), product names, the command line tool's own output, and the labels in the log file.
- To add a language, add `Resources/<language>.lproj/` with `Localizable.strings` and `InfoPlist.strings` (the text macOS shows when it asks for Automation).
- Most existing tests run with the Korean table switched on (`KoreanMessagesTestCase`), so the Korean sentences they assert have gone through the whole path: English sentence, translation, values filled in.

Code comments are mostly in Korean for now. New comments in English are welcome.

## Icons

The icon is a key with a slash on it. `swift scripts/make-icon.swift` regenerates `scripts/AppIcon.icns` (`--preview file.png [size]` writes a single image). The menu bar icon is drawn from the same shape as a template image in `StatusIcon.swift`.

## Signing

`build-app.sh` signs with an "Apple Development" certificate when one is in the keychain, and ad-hoc otherwise. With an ad-hoc signature macOS asks for the permissions again after every build, because the app's identity changes. A certificate-signed build uses the Hardened Runtime with one entitlement, `com.apple.security.automation.apple-events`, which the AppleScript connections to Ghostty and iTerm2 need.

## Releasing

Releases are built on a maintainer's Mac. There is no macOS CI.

```sh
./scripts/release.sh                # universal build, Developer ID signature, notarization, stapling → dist/Slash-Command.zip
./scripts/release.sh --no-notarize  # stop after signing
```

The script needs a "Developer ID Application" certificate and a `notarytool` keychain profile named `slashcommand-notary` (`xcrun notarytool store-credentials slashcommand-notary`). It refuses to run when `CHANGELOG.md` has no section for the version in `scripts/Info.plist`. Run it in a login session; over ssh the keychain is locked and `codesign` fails.

Then publish the zip:

```sh
gh release create v0.1.0 dist/Slash-Command.zip --title "Slash Command 0.1.0" --notes-file notes.md
```

Keep the asset name `Slash-Command.zip`. The README links to the latest release, and a stable name keeps `releases/latest/download/Slash-Command.zip` working.
