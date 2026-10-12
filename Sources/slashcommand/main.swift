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

func explicitTarget(_ args: [String]) throws -> Target? {
    // `--bundle <번들 id>`: 그 앱이 맨 앞인 것처럼 대상을 찾는다 — 단축키가 가는 길 그대로(ssh 로 시험할 때).
    if let bundle = value(after: "--bundle", in: args) { return try Detector.target(bundleID: bundle, appName: bundle) }
    let orca = value(after: "--orca", in: args)
    let ghostty = value(after: "--ghostty", in: args)
    let named = value(after: "--agent", in: args).flatMap(Agent.init(rawValue:))
    // 시험 단계의 터미널: 대상을 직접 지정해야 하고 에이전트도 적어야 한다.
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
        return Target(host: host, agent: named, label: id)
    }
    guard orca != nil || ghostty != nil else { return nil }
    // 그 Orca 터미널에서 tmux 가 앞 작업이면 단축키와 같이 그 tmux 칸으로 간다.
    if let orca, let inside = try Detector.orcaTmux(handle: orca) { return inside }
    guard let agent = named ?? orca.flatMap(Detector.orcaAgent(handle:)) else {
        throw SlashCommandError("Cannot tell which agent the target runs. Add --agent <agent>.")
    }
    if let orca { return Target(host: .orca(handle: orca), agent: agent, label: orca) }
    return Target(host: .ghostty(terminalID: ghostty!), agent: agent, label: ghostty!)
}

/// `keep-defaults` 를 따로 띄운다 — `LaunchDefaults.begin` 이 준 표로 그 열기를 지켜본다.
/// `detach` 면 그 프로세스가 진짜 일꾼을 다시 띄우고 끝나기를 기다린다: 일꾼이 우리(곧 에이전트)의 자식으로 남지 않는다.
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

/// 이 프로그램을 그 인자로 따로 띄운다. `wait` 면 `--detach` 를 붙여 띄우고 끝나기를 기다린다 — 그 프로세스가 진짜 일꾼을 다시 띄우고
/// 바로 끝나므로, 일꾼이 우리(곧 에이전트로 바뀔 프로세스)의 자식으로 남지 않는다.
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
        let target = try explicitTarget(args) ?? Detector.frontmost()
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
        let target = try explicitTarget(args) ?? Detector.frontmost()
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
        let config = try store.load()
        let planned = try Switcher(config: config, codexModels: { CodexModels(models: []) }).preset(slot: slot, agent: agent)
        // `--dry-run` 은 바로 뒤에 올 때만 우리 것이다 — 그 뒤의 인자는 전부 에이전트에 넘긴다.
        let dryRun = args.count > 3 && args[3] == "--dry-run"
        if agent == .opencode {
            // opencode 2 는 여는 옵션에 `--model` 이 없다(2.0.25 실측). 없는 옵션을 넘기면 opencode 가 오류로 끝난다.
            // 그래서 그냥 열고, 따로 띄운 일꾼(`follow`)이 «이 터미널» 에 입력창이 뜨기를 기다렸다가 단축키와 같은 전환을 돌린다.
            let help = Proc.run("/usr/bin/env", ["opencode", "--help"], timeout: 20)
            if help.ok, !Launch.openCodeTakesModel(help: help.out + help.err) {
                let extra = Array(args.dropFirst(dryRun ? 4 : 3))
                // 이 터미널이 무엇인지는 환경변수로만 안다(포커스나 폴더로 짐작하지 않는다 — 같은 폴더의 다른 터미널일 수 있다. PR #29 리뷰).
                guard let host = Launch.currentTerminal(environment: ProcessInfo.processInfo.environment), let launched = Follow.Launched.current() else {
                    fail("this OpenCode version has no option to choose the model when it opens (`opencode --help` lists no --model), and this terminal cannot be addressed to switch after it opens (Orca · iTerm2 · WezTerm · kitty with remote control · tmux can; Ghostty gives a session no way to know its own terminal). Open the session, then switch with the shortcut.")
                }
                // 일꾼은 «이 프로세스»(곧 opencode 가 된다)가 살아 있는 동안만 따른다.
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
        // 화면 이름이 아니라 id 를 받는 에이전트는 그 CLI 의 모델 목록에서 id 를 찾는다.
        var resolved: Launch.Resolved?
        if let listing = Launch.listing(agent: agent) {
            let result = Proc.run("/usr/bin/env", listing, timeout: 40)
            guard result.ok else {
                let detail = result.timedOut ? "timed out" : (result.err + result.out).trimmingCharacters(in: .whitespacesAndNewlines)
                fail("could not list the \(agent.displayName) models (\(listing.joined(separator: " "))): \(detail)")
            }
            // opencode 는 제공자를 화면에 «이름» 으로 보여 준다. 그 이름은 opencode 의 모델 캐시와, 직접 넣은 제공자라면
            // «적용된 설정»(`opencode debug config`)에 있다. 둘 다 못 읽으면 id 로만 맞춘다. 설정의 값은 찍지 않는다(이름만 쓴다).
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
            // cursor 는 `--model` 로 연 모델을 새 세션 기본값으로도 저장한다 — 연 «전» 값을 따로 띄운 프로세스가 되돌린다.
            if config.keepDefaults, let model = resolved?.model, Launch.savesLaunchModelAsDefault(agent: agent) {
                let ticket = try LaunchDefaults.begin(agent: agent, model: model)
                do {
                    try spawnDefaultsKeeper(agent: agent, ticket: ticket, detach: true)
                } catch {
                    LaunchDefaults.end(ticket: ticket)
                    throw error
                }
            }
            // 이 프로세스를 에이전트로 바꾼다 — 터미널에서 직접 친 것과 같다.
            var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
            argv.append(nil)
            execvp(command[0], argv)
            fail("could not run \(command[0]): \(String(cString: strerror(errno)))")
        }
    case "follow":
        // 내부용 — `run` 이 부른다. 방금 연 세션의 입력창이 그 터미널에 뜨기를 기다렸다가 프리셋을 적용한다.
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
        // 내부용 — `run` 이 부른다. 그 열기가 쓴 새 세션 기본값을 1분 동안 연 전 값으로 되돌린다.
        guard args.count >= 3, let agent = Agent(rawValue: args[1]) else { fail("slashcommand keep-defaults <agent> <ticket>") }
        if args.contains("--detach") {
            // 곧 에이전트로 바뀔 프로세스의 자식으로 남지 않게, 한 번 더 띄우고 바로 끝난다.
            try spawnDefaultsKeeper(agent: agent, ticket: args[2], detach: false)
        } else {
            LaunchDefaults.keep(agent: agent, ticket: args[2], rounds: 400, sleep: { usleep(UInt32($0) * 1000) })
        }
    case "where":
        let target = try explicitTarget(args) ?? Detector.frontmost()
        print("\(target.host.appName) · \(target.agent.rawValue) · \(target.label)")
        if case .orca = target.host, let payload = try? Detector.orcaTerminals(), let found = try? Detector.orcaActive(payload: payload) {
            print("visible via   \(found.source)")
        }
    case "doctor":
        let target = try explicitTarget(args) ?? Detector.frontmost()
        print("target        \(target.host.appName) · \(target.agent.rawValue) · \(target.label)")
        if case .ghostty = target.host { print("accessibility \(GhosttyScreen.trusted() ? "allowed" : "not allowed")") }
        if case .iterm = target.host {
            print("accessibility \(GhosttyScreen.trusted() ? "allowed" : "not allowed")")
            ITermBroadcast.report().forEach { print($0) }
        }
        AgentVersions.report(for: target.agent).lines.forEach { print($0) }
        let io = try Switcher.terminalIO(for: target)
        if let screen = io.screen() {
            print("screen read   ok (\(screen.count) lines)")
            print("input box     \(Readiness.inputVisible(agent: target.agent, screen: screen) ? "visible — can switch" : "not visible — will not switch")")
            // 시험 표본을 만들 때: 제품이 읽는 «그대로» 의 화면을 파일로 저장한다(`orca terminal read` 의 tail 은 아래쪽 줄이 빠질 수 있다).
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
        OrcaProbe.run(seconds: value(after: "--seconds", in: args).flatMap(Double.init) ?? 30)
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
        print(usage)
        exit(args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
