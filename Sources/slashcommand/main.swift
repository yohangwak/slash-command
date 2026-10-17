import Foundation
import SlashCommandCore

let usage = """
slashcommand — switch the model and effort of the agent in the frontmost terminal to a preset

  slashcommand apply <number> [target] [--trace]   apply a preset (--trace: time per step)
  slashcommand effort <up|down> [target] [--trace]   keep the model, move the effort one level
  slashcommand run <number> <claude|codex|grok|cursor|antigravity|opencode> [--dry-run] [args…]   open a new session in this terminal with that preset
                                       (OpenCode 2 cannot be told the model when it opens: it is opened, then switched in this terminal)
  slashcommand where                   the frontmost terminal and its agent
  slashcommand probe-orca [--seconds N]  record when Orca's "visible terminal" signals change, on one clock (for testing; sends nothing)
  slashcommand doctor [target] [--screen [--lines N]] [--dump file.json]  check the target, screen reading and input box (sends nothing)
  slashcommand list                    the presets
  slashcommand plan <number> <claude|codex>   print the keys that would be sent (runs nothing)
  slashcommand path                    where the presets file is

target (default: the frontmost terminal of the frontmost app):
  --orca <handle> [--agent <agent>]
  --ghostty <terminal id> --agent <agent>
  --bundle <bundle id>   as if that app were the frontmost one (the path a hotkey takes)
also found as the frontmost terminal: iTerm2, WezTerm, kitty (remote control on), and tmux inside any of them. Or name one:
  --tmux <pane> [--tmux-socket <name or path>] --agent <agent>
  --kitty <window id> --kitty-socket unix:/path --agent <agent>
  --wezterm <pane id> [--wezterm-socket <path>] --agent <agent>
  --iterm <session unique id> --agent <agent>
agents: claude · codex · grok · cursor · antigravity · opencode

Output of this tool is in English; the sentences an agent switch reports follow the system language.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("slashcommand: \(message)\n".utf8))
    exit(1)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

/// Announce just before the Automation consent prompt appears. It waits for the answer, so this keeps it from looking stuck.
func noteAutomationPrompt() {
    FileHandle.standardError.write(Data("macOS is asking whether this terminal may control that app — answer the prompt…\n".utf8))
}

func explicitTarget(_ args: [String]) throws -> Target? {
    // `--bundle <bundle id>`: find the target as if that app were frontmost, the same path the hotkey takes (for testing over ssh).
    if let bundle = value(after: "--bundle", in: args) {
        #if os(macOS)
        try AutomationConsent.ensure(bundleID: bundle, appName: bundle, willAsk: noteAutomationPrompt)
        return try Detector.target(bundleID: bundle, appName: bundle)
        #else
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
        #endif
    }
    #if os(Windows)
    if let app = value(after: "--app", in: args) { return try Detector.target(app: app) }
    #endif
    let orca = value(after: "--orca", in: args)
    let ghostty = value(after: "--ghostty", in: args)
    let named = value(after: "--agent", in: args).flatMap(Agent.init(rawValue:))
    // Test-stage terminal: the target must be specified directly, and so must the agent.
    let more: [(String, (String) -> TerminalHost?)] = [
        ("--tmux", { .tmux(socket: value(after: "--tmux-socket", in: args), pane: $0) }),
        ("--kitty", { id in value(after: "--kitty-socket", in: args).map { .kitty(socket: $0, window: id) } }),
        ("--wezterm", { .wezterm(socket: value(after: "--wezterm-socket", in: args), pane: $0) }),
        ("--iterm", { .iterm(sessionID: $0) }),
    ]
    for (flag, make) in more {
        guard let id = value(after: flag, in: args) else { continue }
        guard let host = make(id) else { throw SlashCommandError("--kitty needs --kitty-socket unix:/path.") }
        guard let named else { throw SlashCommandError("\(flag) needs --agent <agent>.") }
        #if os(Windows)
        if flag == "--wezterm" { return try Detector.windowsWezTermExplicit(pane: id, agent: named, socket: value(after: "--wezterm-socket", in: args)) }
        #endif
        return Target(host: host, agent: named, label: id)
    }
    guard orca != nil || ghostty != nil else { return nil }
    #if os(macOS)
    // If tmux is the foreground job in that Orca terminal, go to that tmux pane, same as the hotkey.
    if let orca, let inside = try Detector.orcaTmux(handle: orca) { return inside }
    guard let agent = named ?? orca.flatMap(Detector.orcaAgent(handle:)) else {
        throw SlashCommandError("Cannot tell which agent the target runs. Add --agent <agent>.")
    }
    #elseif os(Windows)
    if let orca { _ = try Detector.orcaTmux(handle: orca) }
    guard let agent = named ?? orca.flatMap(Detector.orcaAgent(handle:)) else {
        throw SlashCommandError("Cannot tell which agent the target runs. Add --agent <agent>.")
    }
    #else
    // Without the process table this OS cannot tell whether tmux is the foreground job in that Orca terminal,
    // and reading through Orca would then mix tmux panes into one screen. Stop instead of guessing.
    guard let agent = named, orca == nil else {
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
    }
    #endif
    if let orca { return Target(host: .orca(handle: orca), agent: agent, label: orca) }
    return Target(host: .ghostty(terminalID: ghostty!), agent: agent, label: ghostty!)
}

/// Starts `keep-defaults` separately, watching that launch with the table `LaunchDefaults.begin` returned.
/// With `detach`, that process starts the real worker again and waits for it to finish, so the worker does not remain a child of us (that is, of the agent).
func spawnDefaultsKeeper(agent: Agent, ticket: String, detach: Bool) throws {
    guard let executable = Bundle.main.executableURL else { throw SlashCommandError("could not find this program's own path") }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["keep-defaults", agent.rawValue, ticket] + (detach ? ["--detach"] : [])
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    if detach { process.waitUntilExit() }
}

/// Starts this program separately with those arguments. With `wait`, it is started with `--detach` and waited on: that process starts the real worker again and
/// exits right away, so the worker does not remain a child of us (the process that will turn into the agent).
func spawnDetached(_ arguments: [String], wait: Bool = true) throws {
    guard let executable = Bundle.main.executableURL else { throw SlashCommandError("could not find this program's own path") }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments + (wait ? ["--detach"] : [])
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    if wait { process.waitUntilExit() }
}

func describe(_ step: Step) -> String {
    switch step {
    case .text(let text): return "type    \(text.debugDescription)"
    case .key(let key): return "key     \(key)"
    case .wait(let ms): return "wait    \(ms)ms"
    case .expect(let needle, let bottom, let timeoutMs, _, _):
        return "expect  \(needle.debugDescription) on screen\(bottom.map { " (bottom \($0) lines)" } ?? "") (up to \(timeoutMs)ms)"
    case .expectPicker(let header, let footer, let timeoutMs, _, _):
        return "expect  a picker at the bottom\(header.map { " \($0.debugDescription)" } ?? "")\(footer.map { ", hint \($0.debugDescription)" } ?? "") (up to \(timeoutMs)ms)"
    case .arm: return "mark    the defaults file's modification time"
    case .expectResult(let prefix, _, _, let timeoutMs, _): return "expect  result line \(prefix.debugDescription)… (up to \(timeoutMs)ms)"
    case .selectRow(let label, let via, let timeoutMs, _, _):
        return "row     cursor to \(label.debugDescription)\(via.map { " (if absent, under \($0.debugDescription))" } ?? "") (up to \(timeoutMs)ms)"
    case .setEffort(let level, let timeoutMs, _, _): return "effort  picker's effort line to \(level.debugDescription) (up to \(timeoutMs)ms)"
    case .stepRow(let up, let timeoutMs, _): return "row     cursor one row \(up ? "above" : "below") the current value (up to \(timeoutMs)ms)"
    case .expectCurrentRow: return "expect  the cursor is on the current model's row (✔)"
    case .stepEffort(let up, let timeoutMs, _): return "effort  one level \(up ? "up (→)" : "down (←)") (up to \(timeoutMs)ms)"
    case .expectInput(let agent, _, let timeoutMs, _, _): return "expect  the picker closed and the \(agent.rawValue) input box is visible (up to \(timeoutMs)ms)"
    case .closePicker: return "close   Esc, only while the picker is showing"
    case .capture(let prefixes, _): return "capture result text (\(prefixes.joined(separator: " / "))…)"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let store = ConfigStore()

do {
    switch args.first {
    case "apply":
        guard args.count >= 2, let slot = Int(args[1]) else { fail("a preset number is needed.\n\n\(usage)") }
        var switcher = Switcher(config: try store.load())
        let trace = args.contains("--trace") ? Trace() : nil
        switcher.trace = trace
        switcher.onAwaitingUser = { model in
            FileHandle.standardError.write(Data("claude is asking whether to switch to \(model) — choose Enter (switch) or 2 (cancel) in that terminal…\n".utf8))
        }
        let target = try explicitTarget(args) ?? Detector.frontmost(willAskAutomation: noteAutomationPrompt)
        trace?.mark("find target")
        defer { if let trace { print("timing: " + trace.report) } }
        let result = try switcher.apply(slot: slot, to: target)
        print("\(result.target.host.appName) · \(result.target.agent.rawValue) · \(result.target.label)")
        print("→ \(result.summary)")
        if !result.confirmed { print("(the agent's confirmation text was not seen)") }
        if trace != nil { result.confirmations.forEach { print("confirmation: \($0)") } }
        if let warning = result.warning { print("⚠️ \(warning)") }
    case "effort":
        guard args.count >= 2, ["up", "down"].contains(args[1]) else { fail("slashcommand effort <up|down> [target]") }
        var switcher = Switcher(config: try store.load())
        let trace = args.contains("--trace") ? Trace() : nil
        switcher.trace = trace
        let target = try explicitTarget(args) ?? Detector.frontmost(willAskAutomation: noteAutomationPrompt)
        trace?.mark("find target")
        defer { if let trace { print("timing: " + trace.report) } }
        switcher.onAwaitingUser = { value in
            FileHandle.standardError.write(Data("claude is asking whether to switch to \(value) — choose Enter (switch) or 2 (cancel) in that terminal…\n".utf8))
        }
        let result = try switcher.stepEffort(up: args[1] == "up", on: target)
        print("\(result.target.host.appName) · \(result.target.agent.rawValue) · \(result.target.label)")
        print("→ \(result.summary)")
    case "run":
        guard args.count >= 3, let slot = Int(args[1]), let agent = Agent(rawValue: args[2]) else {
            fail("slashcommand run <number> <claude|codex|grok|cursor|antigravity|opencode> [args…]")
        }
        #if os(macOS)
        let config = try store.load()
        let planned = try Switcher(config: config, codexModels: { CodexModels(models: []) }).preset(slot: slot, agent: agent)
        // `--dry-run` is ours only when it comes right after; every argument after it goes to the agent.
        let dryRun = args.count > 3 && args[3] == "--dry-run"
        if agent == .opencode {
            // opencode 2 has no `--model` among its launch options (measured on 2.0.25). Passing an unknown option makes opencode exit with an error.
            // So it just launches, and a separately started worker (`follow`) waits for the input box to appear in "this terminal", then runs the same switch as the hotkey.
            let help = Proc.run("/usr/bin/env", ["opencode", "--help"], timeout: 20)
            if help.ok, !Launch.openCodeTakesModel(help: help.out + help.err) {
                let extra = Array(args.dropFirst(dryRun ? 4 : 3))
                // This terminal is identified only by environment variables (not guessed from focus or folder; it could be another terminal in the same folder. PR #29 review).
                guard let host = Launch.currentTerminal(environment: ProcessInfo.processInfo.environment), let launched = Follow.Launched.current() else {
                    fail("this OpenCode version has no option to choose the model when it opens (`opencode --help` lists no --model), and this terminal cannot be addressed to switch after it opens (Orca · iTerm2 · WezTerm · kitty with remote control · tmux can; Ghostty gives a session no way to know its own terminal). Open the session, then switch with the shortcut.")
                }
                // The worker follows only while "this process" (which becomes opencode) is alive.
                let follow = ["follow", String(slot), "--launched", launched.argument] + Launch.targetArguments(host: host, agent: agent)
                let command = [agent.executable] + extra
                if dryRun {
                    print(command.joined(separator: " "))
                    print("then, in this terminal: slashcommand \(follow.joined(separator: " "))")
                    exit(0)
                }
                try spawnDetached(follow)
                var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
                argv.append(nil)
                execvp(command[0], argv)
                fail("could not run \(command[0]): \(String(cString: strerror(errno)))")
            }
        }
        // An agent that takes an id rather than an on-screen name looks the id up in that CLI's model list.
        var resolved: Launch.Resolved?
        if let listing = Launch.listing(agent: agent) {
            let result = Proc.run("/usr/bin/env", listing, timeout: 40)
            guard result.ok else {
                let detail = result.timedOut ? "timed out" : (result.err + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
                fail("could not list the \(agent.displayName) models (\(listing.joined(separator: " "))): \(detail)")
            }
            // opencode shows the provider on screen by "name". That name is in opencode's model cache and, for a provider added by hand,
            // in the "applied config" (`opencode debug config`). If neither can be read, match by id only. Values in the config are never printed (names only).
            var providerNames: [String: String] = [:]
            if agent == .opencode {
                let config = Proc.run("/usr/bin/env", ["opencode", "debug", "config"], timeout: 20)
                providerNames = Launch.openCodeProviderNames(cache: try? Data(contentsOf: Launch.openCodeModelsCache),
                                                             config: config.ok ? Data(config.out.utf8) : nil)
            }
            resolved = try Launch.resolve(agent: agent, preset: planned, listing: result.out, providerNames: providerNames)
            if let note = resolved?.note { FileHandle.standardError.write(Data("slashcommand: \(note)\n".utf8)) }
        }
        let command = Launch.command(agent: agent, preset: planned, model: resolved?.model, extra: Array(args.dropFirst(dryRun ? 4 : 3)))
        if dryRun {
            print(command.joined(separator: " "))
        } else {
            // cursor also saves the model opened with `--model` as the default for new sessions; a separately started process restores the value from before the launch.
            if config.keepDefaults, let model = resolved?.model, Launch.savesLaunchModelAsDefault(agent: agent) {
                let ticket = try LaunchDefaults.begin(agent: agent, model: model)
                do {
                    try spawnDefaultsKeeper(agent: agent, ticket: ticket, detach: true)
                } catch {
                    LaunchDefaults.end(ticket: ticket)
                    throw error
                }
            }
            // Turn this process into the agent, the same as typing it directly in the terminal.
            var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
            argv.append(nil)
            execvp(command[0], argv)
            fail("could not run \(command[0]): \(String(cString: strerror(errno)))")
        }
        #else
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
        #endif
    case "follow":
        // Internal: called by `run`. Waits for the input box of the just-opened session to appear in that terminal, then applies the preset.
        guard args.count >= 2, let slot = Int(args[1]) else { fail("slashcommand follow <number> <target>") }
        if args.contains("--detach") {
            try spawnDetached(args.filter { $0 != "--detach" }, wait: false)
        } else {
            guard let target = try explicitTarget(args), let launched = value(after: "--launched", in: args).flatMap(Follow.Launched.init(argument:)) else {
                fail("slashcommand follow needs a target and --launched <pid:start>")
            }
            let outcome = Follow.run(slot: slot, target: target, launched: launched, config: try store.load())
            Follow.log("run \(slot) \(target.agent.rawValue)@\(target.host.appName): \(outcome)")
        }
    case "keep-defaults":
        // Internal: called by `run`. Restores, for one minute, the new-session default that launch wrote to its pre-launch value.
        guard args.count >= 3, let agent = Agent(rawValue: args[1]) else { fail("slashcommand keep-defaults <agent> <ticket>") }
        if args.contains("--detach") {
            // So it does not remain a child of the process that will turn into the agent: start once more and exit right away.
            try spawnDefaultsKeeper(agent: agent, ticket: args[2], detach: false)
        } else {
            LaunchDefaults.keep(agent: agent, ticket: args[2], rounds: 400, sleep: {
                #if os(macOS)
                usleep(UInt32($0) * 1000)
                #else
                Thread.sleep(forTimeInterval: Double($0) / 1000)
                #endif
            })
        }
    case "where":
        let target = try explicitTarget(args) ?? Detector.frontmost(willAskAutomation: noteAutomationPrompt)
        print("\(target.host.appName) · \(target.agent.rawValue) · \(target.label)")
        #if os(macOS)
        if case .orca = target.host, let payload = try? Detector.orcaTerminals(), let found = try? Detector.orcaActive(payload: payload) {
            print("visible via   \(found.source)")
        }
        #endif
    case "doctor":
        let target = try explicitTarget(args) ?? Detector.frontmost(willAskAutomation: noteAutomationPrompt)
        print("target        \(target.host.appName) · \(target.agent.rawValue) · \(target.label)")
        #if os(macOS)
        if case .ghostty = target.host { print("accessibility \(GhosttyScreen.trusted() ? "allowed" : "not allowed")") }
        if case .iterm = target.host {
            print("accessibility \(GhosttyScreen.trusted() ? "allowed" : "not allowed")")
            ITermBroadcast.report().forEach { print($0) }
        }
        #endif
        AgentVersions.report(for: target.agent).lines.forEach { print($0) }
        let io = try Switcher.terminalIO(for: target)
        if let screen = io.screen() {
            #if os(Windows)
            if case .orca = target.host { print("runtime       \(OrcaRuntime.windowsTransportStatus())") }
            #endif
            print("screen read   ok (\(screen.count) lines)")
            print("input box     \(Readiness.inputVisible(agent: target.agent, screen: screen) ? "visible — can switch" : "not visible — will not switch")")
            // When making a test sample: save the screen exactly as the product reads it to a file (the tail of `orca terminal read` can drop the bottom lines).
            if let path = value(after: "--dump", in: args), let snapshot = io.snapshot() {
                let object: [String: Any] = ["draft": snapshot.draft as Any, "tail": snapshot.lines]
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
                    try? data.write(to: URL(fileURLWithPath: path))
                    print("screen saved: \(path)")
                }
            }
            if args.contains("--screen") {
                let count = value(after: "--lines", in: args).flatMap(Int.init) ?? 8
                screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(count).forEach { print("  | " + $0.prefix(140)) }
            }
        } else {
            print("screen read   failed — will not switch")
        }
    case "probe-orca":
        #if os(macOS)
        OrcaProbe.run(seconds: value(after: "--seconds", in: args).flatMap(Double.init) ?? 30)
        #else
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
        #endif
    case "list":
        let config = try store.load()
        for (index, slot) in config.slots.enumerated() {
            print("\(index + 1)  \(slot.listing)")
        }
    case "plan":
        guard args.count >= 3, let slot = Int(args[1]), let agent = Agent(rawValue: args[2]) else {
            fail("slashcommand plan <number> <claude|codex>")
        }
        let planned = try Switcher(config: try store.load()).plan(slot: slot, agent: agent)
        print("\(agent.rawValue) \(planned.preset.model) · \(planned.preset.effort)")
        planned.steps.forEach { print("  " + describe($0)) }
        if let fallback = planned.fallback {
            print("if the picker has no row for that model (the default is changed and put back):")
            fallback.forEach { print("  " + describe($0)) }
        }
    case "path":
        print(store.url.path)
    default:
        #if os(Windows)
        print(usage.replacingOccurrences(of: "--bundle <bundle id>", with: "--app orca"))
        #else
        print(usage)
        #endif
        exit(args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
