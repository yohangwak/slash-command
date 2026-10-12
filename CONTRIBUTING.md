# Contributing

Thanks for your interest. Slash Command is a small project, and the most useful contributions are usually small too.

## What helps most

- **A new agent version broke switching.** Slash Command reads each agent's screen, so this is the most common problem. Open an issue with the output of `slashcommand doctor --screen`. Read it before posting and remove anything private, because it contains the visible lines of your terminal.
- **Translation corrections.** Every language except English and Korean is machine translated. Edit the line in `Resources/<language>.lproj/Localizable.strings` and open a pull request.
- **Bug reports** with the terminal, the agent and its version, and the relevant lines of `~/Library/Logs/SlashCommand/slashcommand.log`. The log holds no screen text.
- **A new terminal or agent.** Please open an issue first so we can agree on the approach. [docs/CONTRACT.md](docs/CONTRACT.md) lists what a terminal connection has to guarantee.

## Pull requests

1. Fork the repository and create a branch.
2. Make the change, with a test. The logic lives in `SlashCommandCore` and is tested without a terminal, using screen samples.
3. Run `swift build && swift test`. Tests need Xcode. There is no macOS CI, so this step is yours.
4. If you tested against a real agent, follow the rules in [docs/development.md](docs/development.md#rules-for-testing-against-real-agents).
5. Open the pull request and say what you checked and how.

Keep a pull request to one change. Match the style of the code around it.

### What a change must not do

The [safety rules](docs/safety.md) are the point of this app. A change is not accepted if it:

- sends keys without first seeing the agent's input box,
- treats "could not read the screen" as "nothing is in the way",
- writes screen text to the log, or
- adds network access.

## Reporting a security problem

Please do not open a public issue. See [SECURITY.md](SECURITY.md).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
