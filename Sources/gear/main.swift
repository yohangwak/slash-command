import Foundation
import GearCore

let usage = """
gear — 맨 앞 터미널의 claude·codex 모델과 effort 를 프리셋으로 바꾼다

  gear apply <번호> [대상]     프리셋 적용
  gear where                   지금 맨 앞 터미널과 에이전트
  gear doctor [대상] [--screen]  대상·화면 읽기·입력창 상태 점검(아무것도 보내지 않음)
  gear list                    프리셋 목록
  gear plan <번호> <claude|codex>   보낼 키 순서만 출력(실행하지 않음)
  gear path                    프리셋 파일 위치

대상(생략하면 맨 앞 앱의 맨 앞 터미널):
  --orca <핸들> [--agent <claude|codex>]
  --ghostty <터미널 id> --agent <claude|codex>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gear: \(message)\n".utf8))
    exit(1)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func explicitTarget(_ args: [String]) throws -> Target? {
    let orca = value(after: "--orca", in: args)
    let ghostty = value(after: "--ghostty", in: args)
    guard orca != nil || ghostty != nil else { return nil }
    let named = value(after: "--agent", in: args).flatMap(Agent.init(rawValue:))
    guard let agent = named ?? orca.flatMap(Detector.orcaAgent(handle:)) else {
        throw GearError("대상의 에이전트를 알 수 없습니다. --agent claude|codex 를 붙여 주세요.")
    }
    if let orca { return Target(host: .orca(handle: orca), agent: agent, label: orca) }
    return Target(host: .ghostty(terminalID: ghostty!), agent: agent, label: ghostty!)
}

func describe(_ step: Step) -> String {
    switch step {
    case .text(let text): return "입력  \(text.debugDescription)"
    case .key(let key): return "키    \(key)"
    case .wait(let ms): return "대기  \(ms)ms"
    case .expect(let needle, let timeoutMs, _, _): return "확인  화면에 \(needle.debugDescription) (최대 \(timeoutMs)ms)"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let store = ConfigStore()

do {
    switch args.first {
    case "apply":
        guard args.count >= 2, let slot = Int(args[1]) else { fail("번호가 필요합니다.\n\n\(usage)") }
        let switcher = Switcher(config: try store.load())
        let target = try explicitTarget(args) ?? Detector.frontmost()
        let result = try switcher.apply(slot: slot, to: target)
        print("\(result.target.host.appName) · \(result.target.agent.rawValue) · \(result.target.label)")
        print("→ \(result.summary)")
        if let warning = result.warning { print("⚠️ \(warning)") }
    case "where":
        let target = try Detector.frontmost()
        print("\(target.host.appName) · \(target.agent.rawValue) · \(target.label)")
    case "doctor":
        let target = try explicitTarget(args) ?? Detector.frontmost()
        print("대상        \(target.host.appName) · \(target.agent.rawValue) · \(target.label)")
        if case .ghostty = target.host { print("손쉬운 사용  \(GhosttyScreen.trusted() ? "허용됨" : "허용 안 됨")") }
        let io = try Switcher.terminalIO(for: target)
        if let screen = io.screen() {
            print("화면 읽기    됨 (\(screen.count)줄)")
            print("입력창       \(Readiness.inputVisible(agent: target.agent, screen: screen) ? "보임 — 전환 가능" : "안 보임 — 전환하지 않음")")
            if args.contains("--screen") {
                screen.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).forEach { print("  | " + $0.prefix(100)) }
            }
        } else {
            print("화면 읽기    안 됨 — 전환하지 않음")
        }
    case "list":
        let config = try store.load()
        for (index, slot) in config.slots.enumerated() {
            let claude = slot.claude.map { "\($0.model) · \($0.effort)" } ?? "—"
            let codex = slot.codex.map { "\($0.model) · \($0.effort)" } ?? "—"
            print("\(index + 1)  \(slot.name)\tclaude: \(claude)\tcodex: \(codex)")
        }
    case "plan":
        guard args.count >= 3, let slot = Int(args[1]), let agent = Agent(rawValue: args[2]) else {
            fail("gear plan <번호> <claude|codex>")
        }
        let planned = try Switcher(config: try store.load()).plan(slot: slot, agent: agent)
        print("\(planned.slot.name) — \(planned.preset.model) · \(planned.preset.effort)")
        planned.steps.forEach { print("  " + describe($0)) }
    case "path":
        print(store.url.path)
    default:
        print(usage)
        exit(args.isEmpty || args.first == "help" || args.first == "--help" ? 0 : 1)
    }
} catch {
    fail("\(error)")
}
