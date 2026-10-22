/// Checks CLI options before any target detection or terminal access takes place.
public enum CommandLineCheck {
    public static func problem(in args: [String]) -> String? {
        guard let command = args.first else { return nil }
        // These commands are private entry points whose own handlers validate their arguments.
        if command.hasPrefix("__") || ["follow", "keep-defaults"].contains(command) { return nil }
        if command == "run" {
            guard args.count >= 3 else { return "run needs a preset number and an agent." }
            guard Agent(rawValue: args[2]) != nil else { return "unknown agent: \(args[2])" }
            // After the agent and optional --dry-run, all arguments belong to the agent.
            return nil
        }

        let valueOptions: Set<String> = [
            "--bundle", "--app", "--console", "--orca", "--ghostty", "--agent",
            "--tmux", "--tmux-socket", "--kitty", "--kitty-socket",
            "--wezterm", "--wezterm-socket", "--iterm", "--dump", "--lines", "--seconds",
            "--launched",
        ]
        let flags: Set<String> = ["--trace", "--screen", "--dry-run", "--detach"]
        // How many plain arguments each command takes. A stray one is usually a target whose option was lost (`apply 2 sctest:0.0`)
        // or an empty shell variable (`apply 2 "$T"`), and ignoring it would switch the frontmost session instead.
        let positionalLimit = positionalArguments[command]
        var positionals = 0
        var index = 1
        while index < args.count {
            let option = args[index]
            guard option.hasPrefix("--") else {
                if option.isEmpty { return "empty argument at position \(index)." }
                positionals += 1
                if let limit = positionalLimit, positionals > limit { return "unexpected argument: \(option)" }
                index += 1
                continue
            }
            if flags.contains(option) { index += 1; continue }
            guard valueOptions.contains(option) else { return "unknown option: \(option)" }
            guard index + 1 < args.count, !args[index + 1].isEmpty, !args[index + 1].hasPrefix("--") else {
                return "\(option) needs a value."
            }
            let value = args[index + 1]
            if option == "--agent", Agent(rawValue: value) == nil {
                return "unknown agent: \(value)"
            }
            if option == "--lines", Int(value).map({ $0 > 0 }) != true {
                return "--lines needs a positive integer."
            }
            index += 2
        }
        return nil
    }

    private static let positionalArguments: [String: Int] = [
        "apply": 1, "effort": 1, "plan": 2,
        "where": 0, "doctor": 0, "list": 0, "path": 0, "probe-orca": 0,
    ]
}
