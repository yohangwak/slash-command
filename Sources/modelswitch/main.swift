import Foundation
import ModelSwitchCore

let usage = """
modelswitch — 맨 앞 터미널의 claude·codex 모델과 effort 를 프리셋으로 바꾼다

  modelswitch apply <번호> [대상] [--trace]   프리셋 적용(--trace: 단계별 시간)
  modelswitch where                   지금 맨 앞 터미널과 에이전트
  modelswitch doctor [대상] [--screen]  대상·화면 읽기·입력창 상태 점검(아무것도 보내지 않음)
  modelswitch list                    프리셋 목록
  modelswitch plan <번호> <claude|codex>   보낼 키 순서만 출력(실행하지 않음)
  modelswitch path                    프리셋 파일 위치

대상(생략하면 맨 앞 앱의 맨 앞 터미널):
  --orca <핸들> [--agent <claude|codex>]
  --ghostty <터미널 id> --agent <claude|codex>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("modelswitch: \(message)\n".utf8))
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
        throw ModelSwitchError("대상의 에이전트를 알 수 없습니다. --agent claude|codex 를 붙여 주세요.")
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
    case .arm: return "기준  기본값 파일 수정 시각"
    case .expectResult(let prefix, let timeoutMs, _): return "확인  결과 줄 \(prefix.debugDescription)… (최대 \(timeoutMs)ms)"
    case .selectRow(let label, let via, let timeoutMs, _, _):
        return "행    커서를 \(label.debugDescription) 행에\(via.map { " (없으면 \($0.debugDescription) 하위에서)" } ?? "") (최대 \(timeoutMs)ms)"
    case .expectComposer(let timeoutMs, _, _): return "확인  선택창이 닫히고 입력창이 보임 (최대 \(timeoutMs)ms)"
    case .closePicker: return "닫기  선택창이 보이는 동안만 Esc"
    case .capture(let prefix): return "기록  \(prefix.debugDescription)… 줄"
    }
}

let args = Array(CommandLine.arguments.dropFirst())
let store = ConfigStore()

do {
    switch args.first {
    case "apply":
        guard args.count >= 2, let slot = Int(args[1]) else { fail("번호가 필요합니다.\n\n\(usage)") }
        var switcher = Switcher(config: try store.load())
        let trace = args.contains("--trace") ? Trace() : nil
        switcher.trace = trace
        let target = try explicitTarget(args) ?? Detector.frontmost()
        trace?.mark("대상찾기")
        defer { if let trace { print("시간: " + trace.report) } }
        let result = try switcher.apply(slot: slot, to: target)
        print("\(result.target.host.appName) · \(result.target.agent.rawValue) · \(result.target.label)")
        print("→ \(result.summary)")
        if !result.confirmed { print("(에이전트의 확인 문구는 보지 못했습니다)") }
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
            print("\(index + 1)  \(slot.listing)")
        }
    case "plan":
        guard args.count >= 3, let slot = Int(args[1]), let agent = Agent(rawValue: args[2]) else {
            fail("modelswitch plan <번호> <claude|codex>")
        }
        let planned = try Switcher(config: try store.load()).plan(slot: slot, agent: agent)
        print("\(agent.rawValue) \(planned.preset.model) · \(planned.preset.effort)")
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
