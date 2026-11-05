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

        // Each public command accepts only the options its handler reads. An option a command ignores is refused,
        // because `apply 2 --dry-run` would otherwise send the keys that the user believed were being skipped.
        guard let allowed = allowedOptions[command] else { return nil }
        var seen: Set<String> = []
        var hosts: [String] = []
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
            guard flags.contains(option) || valueOptions.contains(option) else { return "unknown option: \(option)" }
            guard allowed.contains(option) else { return "\(option) is not used by \(command)." }
            #if !os(Windows)
            if windowsOnly.contains(option) { return "\(option) is only for Windows." }
            #endif
            guard seen.insert(option).inserted else { return "\(option) is given more than once." }
            if hostOptions.contains(option) { hosts.append(option) }
            if flags.contains(option) { index += 1; continue }
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
            if option == "--seconds", Double(value).map({ $0.isFinite && $0 > 0 }) != true {
                return "--seconds needs a positive number."
            }
            index += 2
        }
        // The target options choose different terminals; `--agent` and the sockets only describe the chosen one.
        if hosts.count > 1 { return "use only one target option (\(hosts.joined(separator: " ")))." }
        // Without a target option these are ignored and the frontmost session would be switched instead.
        if hosts.isEmpty, let helper = args.first(where: { helperOptions.contains($0) }) {
            #if os(Windows)
            let choices = hostOptions
            #else
            let choices = hostOptions.subtracting(windowsOnly)
            #endif
            return "\(helper) needs a target option (\(choices.sorted().joined(separator: ", ")))."
        }
        return nil
    }

    private static let hostOptions: Set<String> = [
        "--bundle", "--app", "--console", "--orca", "--ghostty", "--tmux", "--kitty", "--wezterm", "--iterm",
    ]
    /// Options that only describe the target that a host option chose.
    private static let helperOptions: Set<String> = ["--agent", "--tmux-socket", "--kitty-socket", "--wezterm-socket"]
    private static let targetOptions: Set<String> = hostOptions.union(helperOptions)
    /// Read only by the Windows build of `main.swift`.
    private static let windowsOnly: Set<String> = ["--app", "--console"]
    private static let valueOptions: Set<String> = targetOptions.union(["--dump", "--lines", "--seconds", "--launched"])
    private static let flags: Set<String> = ["--trace", "--screen", "--dry-run", "--detach"]
    /// The options each public command reads in `main.swift`. `--dry-run` belongs to `run`, and `--detach` and `--launched` to the internal commands.
    private static let allowedOptions: [String: Set<String>] = [
        "apply": targetOptions.union(["--trace"]),
        "effort": targetOptions.union(["--trace"]),
        "where": targetOptions,
        "doctor": targetOptions.union(["--screen", "--lines", "--dump"]),
        "probe-orca": ["--seconds"],
        "list": [], "path": [], "plan": [],
    ]

    private static let positionalArguments: [String: Int] = [
        "apply": 1, "effort": 1, "plan": 2,
        "where": 0, "doctor": 0, "list": 0, "path": 0, "probe-orca": 0,
    ]
}
