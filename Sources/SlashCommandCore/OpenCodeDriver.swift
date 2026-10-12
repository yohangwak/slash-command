import Foundation

// opencode(1.18.35 · 2.0.25)로 모델·variant(effort)를 바꾼다.
//
// 2026-10-07 실측(따로 연 시험 터미널):
// - `/models` 가 «Select model» 대화상자를 연다. 글자를 치면 «이름 + 제공자» 로 걸러지고(`GLM-5.3-Flash OpenCode Go` 한 줄이면 한 행),
//   걸러진 뒤 맨 위 행이 선택 상태다(커서는 색으로만 보인다 — 글자로는 «맨 위 행» 이 근거). `●` 는 지금 모델. Enter 가 고른다.
// - `/variants` 가 «Select variant» 를 연다(Default · low · high · max 등 모델마다). 고르면 입력 상자 안의 `Build · <모델> <제공자> · <variant>` 줄이 바뀐다.
//   기억해 둔 variant 가 없는 모델을 고르면 variant 대화상자가 자동으로 뜬다.
// - 🔴 둘 다 «새 세션 기본값»을 `~/.local/state/opencode/model.json` 의 `recent`(마지막으로 쓴 모델)와 `variant`(모델마다의 variant)로 저장한다.
//   「이 세션만」이 없으므로 전환 뒤 그 두 키만 전환 전 값으로 되돌린다.
// - 작업 중에는 입력 상자 아래 줄이 `esc interrupt` 다. 입력 상자는 그대로 비어 보인다.
//
// 2026-10-11·12 집 맥 실측(2.0.25, 따로 연 시험 세션):
// - 제공자가 둘 이상이면 예전처럼 «이름 + 제공자» 로 걸러지고 걸러진 행 오른쪽에 제공자 칸이 있다.
//   제공자가 하나뿐이면 이름으로만 걸러지고(`Big Pickle OpenCode Zen` → `No results found`, `Big Pickle` → 한 행) 행에 제공자 칸이 없다.
//   그때도 지금 모델의 행에는 `●` 가 붙는다(`● Big Pickle        Free`).
// - 걸러진 행의 순서는 «가장 비슷한 것» 이 아니다: `GLM-5.3 OpenCode Go` 를 치면 `GLM-5.3-Flash` 가 맨 위, `GLM-5.3` 이 둘째다.
//   걸러진 직후 커서는 맨 위 행이고 ↓ 한 번에 한 행씩 내려간다(둘째·셋째 행을 6번 골라 6번 그 행).
// - 대화상자 맨 아래 줄은 `Connect an integration ctrl+a  Favorite ctrl+f`(제공자 하나일 때는 `View all integrations ctrl+a`)다.

public enum OpenCodeScreen {
    public struct Row: Equatable, Sendable {
        /// `GLM-5.3-Flash OpenCode Go` 꼴(이름 + 제공자).
        public let text: String
        public let current: Bool
    }

    static func trimmed(_ screen: [String]) -> [String] {
        var lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: 입력 상자

    /// 입력 상자 = `┃` 줄들 + 그 아래 `╹▀▀▀` 테두리. 맨 아래 네 줄(여백 · 입력 · 여백 · `Build · 모델 · variant`)이 상자다.
    /// 슬래시 명령 목록이 뜨면 그 줄들도 `┃` 로 시작해 위에 이어 붙는다.
    static func box(_ screen: [String]) -> (input: String, model: String, popup: Bool, footer: String)? {
        let lines = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let border = lines.lastIndex(where: { $0.hasPrefix("╹▀") }) else { return nil }
        var rows: [String] = []
        var index = border - 1
        while index >= 0, lines[index].hasPrefix("┃") {
            rows.insert(String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces), at: 0)
            index -= 1
        }
        guard rows.count >= 4, let model = rows.last, model.contains(" · ") else { return nil }
        let input = rows[rows.count - 3]
        let popup = rows.dropLast(4).contains { !$0.isEmpty }
        let footer = lines[(border + 1)...].first { !$0.isEmpty } ?? ""
        return (input, model, popup, footer)
    }

    /// 빈 입력 상자의 자리 표시 문구: `Ask anything… "Fix broken tests"`. 따옴표 안의 예시는 판마다·뜰 때마다 다르다
    /// (2026-10-11 실측, 2.0.25: `"Fix a TODO in the codebase"`) — 꼴로 본다.
    static func isPlaceholder(_ input: String) -> Bool {
        input.range(of: #"^Ask anything… ".*"$"#, options: .regularExpression) != nil
    }

    /// 대화상자의 머리말 줄에서 (제목, 제목이 시작하는 칸). 머리말은 `Select model        esc` 꼴이고, 대화 중에는 왼쪽에 대화 내용이 겹친다
    /// (2026-10-07 실측) — 그래서 줄 맨 앞이 아니라 줄 «안의» `Select …  esc` 를 찾는다.
    static func dialogHeader(_ line: String) -> (title: String, column: Int)? {
        guard let start = line.range(of: "Select ") ?? line.range(of: "Commands") else { return nil }
        let tail = line[start.lowerBound...].trimmingCharacters(in: .whitespaces)
        guard tail.hasSuffix("esc"), tail.range(of: #"^(Select [A-Za-z ]+?|Commands)\s{2,}esc$"#, options: .regularExpression) != nil else { return nil }
        let title = String(tail.dropLast(3)).trimmingCharacters(in: .whitespaces)
        return (title, line.distance(from: line.startIndex, to: start.lowerBound))
    }

    /// «No variants available» 알림(variant 가 없는 모델에서 `/variants` 를 치면 대화상자 대신 뜬다 — 2.0.25).
    /// 대화 내용의 같은 글과 구분하려고 알림 상자의 테두리(`┃ … ┃`)까지 본다.
    static func noVariants(_ screen: [String]) -> Bool {
        screen.contains { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("┃") && text.hasSuffix("┃") && text.contains("No variants available")
        }
    }

    /// 모델 대화상자·변형 대화상자·명령 팔레트가 떠 있는가.
    static func dialogTitle(_ screen: [String]) -> String? {
        screen.lazy.compactMap { dialogHeader($0)?.title }.first
    }

    public static func idle(_ screen: [String]) -> Bool {
        guard dialogTitle(screen) == nil, let box = box(screen), !box.popup else { return false }
        guard box.input.isEmpty || isPlaceholder(box.input) else { return false }
        return !isBusy(footer: box.footer)
    }

    /// 작업 중이면 상자 아래 줄이 `⬝■■■■■■⬝  esc interrupt` 다. 창이 좁으면 오른쪽 안내가 잘리므로 글자 전체가 아니라 «진행 막대 + esc» 꼴로 본다.
    static func isBusy(footer: String) -> Bool {
        footer.contains("interrupt") || footer.range(of: #"^[⬝■▪\s]+esc\b"#, options: .regularExpression) != nil
    }

    public static func draft(_ screen: [String]) -> String? {
        guard let box = box(screen) else { return nil }
        return isPlaceholder(box.input) ? "" : box.input
    }

    /// 입력 상자의 모델 줄(`Build · GLM-5.3-Flash OpenCode Go · high`)에서 (모델, variant).
    public static func status(_ screen: [String]) -> (model: String, variant: String?)? {
        guard let line = box(screen)?.model else { return nil }
        // 줄 오른쪽 끝에 브랜치 이름이 붙는다(`… · high          yohangwak/agents`) — 두 칸 이상 떨어진 뒤는 버린다.
        let parts = line.components(separatedBy: " · ").map { ($0.components(separatedBy: "  ").first ?? $0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        return (parts[1], parts.count >= 3 ? parts[2] : nil)
    }

    // MARK: 대화상자

    /// 열려 있는 대화상자(`Select model` · `Select variant`)의 검색칸 글과 행들. 대화상자는 가운데에 떠 있어 입력 상자의 `┃` 가 왼쪽에 겹친다 —
    /// 머리말의 칸 위치부터 오른쪽만 읽는다.
    public static func dialog(_ screen: [String]) -> (title: String, search: String, rows: [Row])? {
        guard let titleIndex = screen.firstIndex(where: { dialogHeader($0).map { $0.title.hasPrefix("Select ") } == true }),
              let header = dialogHeader(screen[titleIndex]) else { return nil }
        let column = header.column - 2
        func cut(_ line: String) -> String {
            let chars = Array(line)
            guard chars.count > column, column >= 0 else { return "" }
            return String(chars[column...]).trimmingCharacters(in: .whitespaces)
        }
        let title = header.title
        // 대화 중에는 머리말·검색칸·행 사이에 빈 줄(여백)이 끼어 있다 — 첫 비어 있지 않은 줄이 검색칸, 그 뒤 첫 비어 있지 않은 줄부터 빈 줄까지가 행이다.
        var index = titleIndex + 1
        func nextNonBlank() -> String? {
            while index < screen.count {
                let text = cut(screen[index])
                index += 1
                if !text.isEmpty { return text }
            }
            return nil
        }
        guard let search = nextNonBlank() else { return nil }
        var rows: [Row] = []
        if var text = nextNonBlank() {
            // 걸러진 것이 없으면 행 자리에 `No results found` 한 줄이 있다. 맨 아래의 안내 줄도 행이 아니다.
            while !isDialogFooter(text), text != "No results found" {
                var current = false
                if text.hasPrefix("●") { current = true; text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
                rows.append(Row(text: normalizeRow(text), current: current))
                guard index < screen.count else { break }
                let following = cut(screen[index])
                index += 1
                if following.isEmpty { break }
                text = following
            }
        }
        return (title, search, rows)
    }

    /// 대화상자 맨 아래의 안내 줄: `Connect provider …`(1.x) · `Connect an integration ctrl+a  Favorite ctrl+f` · `View all integrations ctrl+a`(2.x).
    static func isDialogFooter(_ text: String) -> Bool {
        text.hasPrefix("Connect provider") || text.hasPrefix("Connect an integration") || text.hasPrefix("View all integrations")
    }

    /// `GLM-5.3-Flash (Favorite)        OpenCode Go` → `GLM-5.3-Flash OpenCode Go`.
    static func normalizeRow(_ text: String) -> String {
        var parts = text.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = parts.first, first.hasSuffix("(Favorite)") { parts[0] = String(first.dropLast("(Favorite)".count)).trimmingCharacters(in: .whitespaces) }
        // 맨 오른쪽의 값 표시 칸(`Free`·`$0.50`)은 모델의 이름이 아니다 — 입력 상자의 모델 줄에도 나오지 않는다.
        // (2026-10-08 실측: 걸러내지 않은 목록의 무료 모델 행 오른쪽에 `Free` 칸이 따로 있다. 이름 «안» 의 Free 는 한 칸 공백이라 떨어지지 않는다.)
        if parts.count >= 2, let last = parts.last, last == "Free" || last.range(of: #"^\$\d"#, options: .regularExpression) != nil { parts.removeLast() }
        return parts.joined(separator: " ")
    }

    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

/// `~/.local/state/opencode/model.json` 의 `recent`·`variant` 두 키.
public struct OpenCodeDefaults: Sendable {
    public let url: URL

    public init(url: URL = OpenCodeDefaults.defaultURL) { self.url = url }

    /// opencode 는 상태를 `$XDG_STATE_HOME/opencode/` 에 둔다(없으면 `~/.local/state`).
    public static var defaultURL: URL { url(stateHome: nil, environment: ProcessInfo.processInfo.environment) }

    static func url(stateHome: String?, environment: [String: String]) -> URL {
        let home = stateHome ?? environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
        return URL(fileURLWithPath: home).appendingPathComponent("opencode/model.json")
    }

    /// 돌고 있는 opencode 프로세스들이 쓰는 상태 폴더들(서로 다른 것만). `orcaHandle` 을 주면 그 Orca 터미널의 프로세스로 좁힌다.
    /// Slash Command 자신의 환경이 아니라 «그 세션의» 환경을 본다 — 셸에서 XDG_STATE_HOME 을 바꿔 띄운 세션이면 기본값 파일도 거기 있다.
    static func stateHomes(processes: [(arguments: [String], environment: [String])], orcaHandle: String?) -> [String] {
        var candidates = processes.filter { AgentProcesses.agent(forCommandLine: $0.arguments.joined(separator: " ")) == .opencode }
        if let orcaHandle {
            let narrowed = candidates.filter { $0.environment.contains("ORCA_TERMINAL_HANDLE=\(orcaHandle)") }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        func value(_ name: String, in environment: [String]) -> String? {
            environment.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let homes = candidates.map { process -> String in
            if let state = value("XDG_STATE_HOME", in: process.environment) { return state }
            let home = value("HOME", in: process.environment) ?? FileManager.default.homeDirectoryForCurrentUser.path
            return home + "/.local/state"
        }
        return Array(Set(homes)).sorted()
    }

    /// 그 세션의 기본값 파일. 세션들이 서로 다른 상태 폴더를 쓰고 어느 쪽인지 좁힐 수 없으면 — 엉뚱한 파일을 «지켰다» 고 말하지 않도록 — 던진다.
    static func resolve(processes: [(arguments: [String], environment: [String])], orcaHandle: String?,
                        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> OpenCodeDefaults {
        // `orcaHandle` 을 줬는데 그 터미널의 opencode 프로세스가 없으면 다른 세션의 것으로 대신하지 않는다.
        if let orcaHandle, !processes.contains(where: { $0.environment.contains("ORCA_TERMINAL_HANDLE=\(orcaHandle)") && AgentProcesses.agent(forCommandLine: $0.arguments.joined(separator: " ")) == .opencode }) {
            throw SlashCommandError(loc("Not switched: the OpenCode process of this Orca terminal was not found, so there is no telling which state folder's default for new sessions to protect."))
        }
        let homes = stateHomes(processes: processes, orcaHandle: orcaHandle)
        switch homes.count {
        case 0:
            // 그 세션의 프로세스를 못 찾았다 — 우리 환경의 폴더가 그 세션의 폴더라는 근거가 없다. 엉뚱한 파일을 «지켰다» 고 하지 않고 멈춘다.
            throw SlashCommandError(loc("Not switched: the process of the OpenCode session was not found, so there is no telling which state folder's default for new sessions to protect."))
        case 1: return OpenCodeDefaults(url: url(stateHome: homes[0], environment: environment))
        default:
            throw SlashCommandError(loc("Not switched: the OpenCode sessions use different state folders (XDG_STATE_HOME), so there is no telling whose default for new sessions to protect (%@).", homes.joined(separator: ", ")))
        }
    }

    static let keys = ["recent", "variant"]

    public func snapshot() -> DefaultsSnapshot { DefaultsFile.snapshot(url) }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case restored
        case failed(String)
    }

    /// 모델 관련 키만 전환 전 값으로 되돌린다(`DefaultsFile.restoreJSON`). 전환 전에 파일이 없었으면 그 키들을 없애고, 남는 것이 없으면 파일도 없앤다.
    public func restore(to snapshot: DefaultsSnapshot) -> Outcome {
        switch DefaultsFile.restoreJSON(url: url, keys: OpenCodeDefaults.keys, to: snapshot, pretty: false, name: "opencode") {
        case .unchanged: return .unchanged
        case .restored: return .restored
        case .failed(let reason): return .failed(reason)
        }
    }

    public func restore(to before: Data) -> Outcome { restore(to: .content(before)) }
}

public struct OpenCodeDriver {
    public let io: TerminalIO
    public let sleep: (Int) -> Void
    public let defaults: OpenCodeDefaults
    public let keepDefaults: Bool

    public init(io: TerminalIO, sleep: @escaping (Int) -> Void, defaults: OpenCodeDefaults = OpenCodeDefaults(), keepDefaults: Bool) {
        self.io = io
        self.sleep = sleep
        self.defaults = defaults
        self.keepDefaults = keepDefaults
    }

    public struct Outcome: Sendable {
        public let confirmations: [String]
        public let warning: String?
    }

    private func poll(timeoutMs: Int, _ condition: ([String]) -> Bool) throws -> [String]? {
        let started = DispatchTime.now()
        var simulated = 0
        while true {
            guard let screen = io.freshSnapshot() else { throw SlashCommandError(loc("Stopped: could not read the OpenCode terminal screen.")) }
            if condition(screen.lines) { return screen.lines }
            let real = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            if max(real, simulated) >= timeoutMs { return nil }
            sleep(Runner.pollMs)
            simulated += Runner.pollMs
        }
    }

    /// 열린 대화상자를 Esc 로 닫고(최대 3번), 입력 상자에 우리가 쓴 글이 남았으면 지운다.
    private func back(clearing leftover: String? = nil) {
        for _ in 0..<3 {
            guard let lines = io.freshSnapshot()?.lines, OpenCodeScreen.dialogTitle(lines) != nil else { break }
            try? io.press(.escape)
            _ = try? poll(timeoutMs: 800) { OpenCodeScreen.dialogTitle($0) == nil }
        }
        guard let leftover, let lines = io.freshSnapshot()?.lines, let now = OpenCodeScreen.draft(lines), !now.isEmpty, leftover.hasPrefix(now) else { return }
        for _ in 0..<(now.count + 1) { try? io.press(.backspace) }
    }

    // MARK: 전환

    public func apply(_ preset: AgentPreset) throws -> Outcome { try guarded { try applyUnguarded(preset) } }

    /// 모델은 그대로 두고 effort 만 한 단계 올리거나 내린다.
    public func stepEffort(up: Bool) throws -> Outcome { try guarded { try stepEffortUnguarded(up: up) } }

    /// 어느 단계에서 던져졌든 — 확정한 뒤 화면을 읽지 못한 경우까지 — 새 세션 기본값을 전환 전 값으로 되돌리고 나서 실패를 알린다.
    /// (각 단계의 실패 처리도 되돌리지만, 화면 읽기 실패는 그 처리를 거치지 않고 곧바로 던져진다.)
    private func guarded(_ body: () throws -> Outcome) throws -> Outcome {
        let before = keepDefaults ? defaults.snapshot() : nil
        // 전환 전 값을 읽지 못했으면 되돌릴 수 없다 — 아무것도 보내기 전에 멈춘다. (파일이 «없던» 것은 괜찮다: 끝나고 다시 없앤다.)
        try DefaultsFile.refuseIfUnreadable(before, name: "opencode")
        do {
            return try body()
        } catch {
            if let before {
                sleep(250)
                _ = defaults.restore(to: before)
            }
            throw error
        }
    }

    private func applyUnguarded(_ preset: AgentPreset) throws -> Outcome {
        try start()
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(clearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        let currentModel = OpenCodeScreen.status(io.freshSnapshot()?.lines ?? [])?.model
        // 낱말 사이는 한 칸으로 — 검색칸에 친 글에서 낱말을 지울 때 글자 수가 맞아야 한다.
        let model = preset.model.split(separator: " ").joined(separator: " ")
        if currentModel.map({ OpenCodeScreen.key($0) }) != OpenCodeScreen.key(model) {
            try pickModel(model, current: currentModel, failure: fail)
        }
        let variant = preset.effort.trimmingCharacters(in: .whitespaces)
        var note: String?
        if !variant.isEmpty {
            // variant 가 없는 모델(Big Pickle 등)은 모델만 맞춘다 — 전에는 모델을 바꾸고도 «대화상자가 열리지 않았다» 며 실패로 알렸다.
            if try !pickVariant(variant, failure: fail) {
                note = loc("This OpenCode model has no variants, so the effort (%@) was not set.", variant)
            }
        } else if OpenCodeScreen.dialogTitle(io.freshSnapshot()?.lines ?? []) == "Select variant" {
            back()   // variant 를 정하지 않는 프리셋 — 자동으로 뜬 대화상자는 그대로 닫는다
        }
        let outcome = try finish(before: before, model: model, failure: fail)
        let warnings = [note, outcome.warning].compactMap { $0 }
        return Outcome(confirmations: outcome.confirmations, warning: warnings.isEmpty ? nil : warnings.joined(separator: " "))
    }

    /// 모델은 그대로 두고 variant 만 한 단계 올리거나 내린다. 단계는 `/variants` 대화상자의 순서(Default · low · high · max…)다.
    private func stepEffortUnguarded(up: Bool) throws -> Outcome {
        try start()
        let before = keepDefaults ? defaults.snapshot() : nil
        func fail(_ message: String, leftover: String? = nil) -> SlashCommandError {
            back(clearing: leftover)
            if let before { sleep(250); _ = defaults.restore(to: before) }
            return SlashCommandError(message)
        }
        // 지금 값: 대화상자의 `●` 가 있으면 그것. 저장해 둔 variant 가 없는 모델은 Default 로 돌면서도 아무 행에도 `●` 가 없다
        // (2026-10-08 실측: DeepSeek V4 Pro) — 그때는 입력 상자의 모델 줄이 근거다(variant 가 적혀 있으면 그 행, 없으면 Default 행).
        let shown = OpenCodeScreen.status(io.freshSnapshot()?.lines ?? [])?.variant
        guard try openVariants(failure: fail) else {
            if let before { sleep(250); _ = defaults.restore(to: before) }
            var error = SlashCommandError(loc("This OpenCode model has no effort levels (it has no variants)."))
            error.nothingToDo = true
            throw error
        }
        guard let dialog = OpenCodeScreen.dialog(io.freshSnapshot()?.lines ?? []),
              let at = dialog.rows.firstIndex(where: \.current)
                ?? dialog.rows.firstIndex(where: { OpenCodeScreen.key($0.text) == OpenCodeScreen.key(shown ?? "Default") }) else {
            throw fail(loc("Nothing was changed: could not read the current value in the OpenCode variant dialog."))
        }
        let next = at + (up ? 1 : -1)
        guard dialog.rows.indices.contains(next) else {
            var error = fail(up ? loc("Already at the highest level (%@).", dialog.rows[at].text) : loc("Already at the lowest level (%@).", dialog.rows[at].text))
            error.nothingToDo = true
            throw error
        }
        try chooseInOpenDialog(text: dialog.rows[next].text, failure: fail)
        return try finish(before: before, model: nil, failure: fail)
    }

    // MARK: 단계

    private func start() throws {
        guard let first = io.freshSnapshot() else { throw SlashCommandError(loc("Not switched: could not read the OpenCode terminal screen.")) }
        guard OpenCodeScreen.idle(first.lines) else {
            if let draft = OpenCodeScreen.draft(first.lines), !draft.isEmpty {
                throw SlashCommandError(loc("Not switched: there is text in the OpenCode input box. Send or clear it, then press again."))
            }
            throw SlashCommandError(loc("Not switched: the OpenCode input box is not visible, or it is working."))
        }
    }

    private func openDialog(command: String, title: String, failure: (String, String?) -> SlashCommandError) throws {
        try io.type(command)
        guard (try poll(timeoutMs: 1500) { OpenCodeScreen.draft($0) == command }) != nil else {
            throw failure(loc("Nothing was sent: the command did not appear in the OpenCode input box."), command)
        }
        try io.press(.enter)
        guard (try poll(timeoutMs: 3000) { OpenCodeScreen.dialog($0)?.title == title }) != nil else {
            throw failure(loc("The OpenCode '%@' dialog did not open.", title), command)
        }
    }

    /// `/variants` 로 «Select variant» 를 연다. 그 모델에 variant 가 없으면 opencode 는 대화상자 대신 알림(«No variants available»)을 띄우고
    /// 입력창으로 돌아온다(2.0.25, 2026-10-12 실측) — 그때는 false.
    private func openVariants(failure: (String, String?) -> SlashCommandError) throws -> Bool {
        let command = "/variants"
        try io.type(command)
        guard (try poll(timeoutMs: 1500) { OpenCodeScreen.draft($0) == command }) != nil else {
            throw failure(loc("Nothing was sent: the command did not appear in the OpenCode input box."), command)
        }
        // 알림은 몇 초 남는다 — Enter 전부터 떠 있었다면(앞서 다른 모델에서 뜬 것) 이번 명령의 답이 아니다. 그때는 대화상자만 기다린다.
        let stale = OpenCodeScreen.noVariants(io.freshSnapshot()?.lines ?? [])
        try io.press(.enter)
        func opened(_ lines: [String]) -> Bool { OpenCodeScreen.dialog(lines)?.title == "Select variant" }
        if stale { return try poll(timeoutMs: 1500, opened) != nil }
        guard let lines = try poll(timeoutMs: 3000, { opened($0) || OpenCodeScreen.noVariants($0) }) else {
            throw failure(loc("The OpenCode '%@' dialog did not open.", "Select variant"), command)
        }
        return opened(lines)
    }

    typealias Dialog = (title: String, search: String, rows: [OpenCodeScreen.Row])

    /// 검색칸의 글이 `text` 가 되고 행들이 두 번 이어서 같게 읽힐 때의 대화상자. 걸러진 행은 글보다 늦게 바뀔 수 있다.
    private func settled(search text: String) throws -> Dialog? {
        var last: [OpenCodeScreen.Row]?
        let lines = try poll(timeoutMs: 2000) { lines in
            guard let dialog = OpenCodeScreen.dialog(lines), dialog.search.lowercased() == text.lowercased() else { last = nil; return false }
            defer { last = dialog.rows }
            return last == dialog.rows
        }
        return lines.flatMap { OpenCodeScreen.dialog($0) }
    }

    /// 걸러진 행 가운데 `text` 와 «같은» 행으로 내려가 Enter 로 고른다. 커서는 글자로 보이지 않는다 — 걸러진 직후에는 맨 위 행에 있고
    /// ↓ 한 번에 한 행씩 내려간다(실측). 비슷한 이름이 위에 오는 일이 흔해서(`GLM-5.3` 위에 `GLM-5.3-Flash`) 맨 위 행만 볼 수는 없다.
    /// 무엇이 골라졌는지는 부른 쪽이 입력 상자의 모델 줄로 확인한다.
    private func choose(row text: String, in dialog: Dialog, failure: (String, String?) -> SlashCommandError) throws {
        guard let at = dialog.rows.firstIndex(where: { OpenCodeScreen.key($0.text) == OpenCodeScreen.key(text) }) else {
            let top = dialog.rows.first?.text ?? loc("no rows")
            throw failure(loc("Not chosen: the OpenCode dialog has no row '%@' (top row: %@).", text, top), nil)
        }
        if at > 0 {
            for _ in 0..<at { try io.press(.down) }
            // 내려가는 사이에 행이 바뀌었으면 센 칸 수가 그 행이 아니다.
            guard let now = OpenCodeScreen.dialog(io.freshSnapshot()?.lines ?? []), now.rows == dialog.rows else {
                throw failure(loc("The OpenCode dialog was not filtered to '%@'.", text), nil)
            }
        }
        try io.press(.enter)
    }

    /// 열려 있는 대화상자에서 `text` 를 쳐 걸러 낸 뒤 그 글과 같은 행을 고른다.
    private func chooseInOpenDialog(text: String, failure: (String, String?) -> SlashCommandError) throws {
        try io.type(text)
        guard let dialog = try settled(search: text) else {
            throw failure(loc("The OpenCode dialog was not filtered to '%@'.", text), nil)
        }
        try choose(row: text, in: dialog, failure: failure)
    }

    /// 검색칸의 글자 `count` 개를 지운다. 한 번에 보낸다 — 터미널에 따라 쓰기 한 번이 수십 ms 다.
    private func erase(_ count: Int) throws {
        if count > 0 { try io.type(String(repeating: Key.backspace.bytes, count: count)) }
    }

    /// 제공자가 하나뿐인 opencode 2 의 대화상자(이름으로만 걸러지고 행에 제공자 칸이 없다)에서 «제공자가 무엇인지» 를 대화상자로 확인한다.
    /// 지금 모델 줄(`Exo Free OpenCode Zen`)에서 뒤의 낱말을 하나씩 지워 가며 걸렀을 때, `●`(지금 모델) 표시가 붙고 남은 글과 같은 행이 나오면
    /// 남은 글이 모델 이름이고 지운 낱말들이 제공자다. 글의 끝이 우연히 같다는 것만으로는 제공자라고 보지 않는다
    /// (`Big Pickle Free OpenCode Zen` 의 `Free OpenCode Zen` 은 `Exo Free OpenCode Zen` 의 끝과 같지만 제공자가 아니다 — PR #24 리뷰).
    /// `typed` 는 지금 검색칸에 들어 있는 글. 돌아올 때 검색칸은 비어 있다.
    private func soleProvider(current: String, typed: String, failure: (String, String?) -> SlashCommandError) throws -> [String]? {
        try erase(typed.count)
        try io.type(current)
        guard try settled(search: current) != nil else {
            throw failure(loc("The OpenCode dialog was not filtered to '%@'.", current), nil)
        }
        var words = current.split(separator: " ").map(String.init)
        var provider: [String] = []
        while words.count > 1 {
            let word = words.removeLast()
            provider.insert(word, at: 0)
            try erase(word.count + 1)
            let name = words.joined(separator: " ")
            guard let dialog = try settled(search: name) else {
                throw failure(loc("The OpenCode dialog was not filtered to '%@'.", name), nil)
            }
            if dialog.rows.contains(where: { $0.current && OpenCodeScreen.key($0.text) == OpenCodeScreen.key(name) }) {
                try erase(name.count)
                return provider
            }
        }
        try erase(words.joined(separator: " ").count)
        return nil
    }

    private func pickModel(_ model: String, current: String?, failure: (String, String?) -> SlashCommandError) throws {
        try openDialog(command: "/models", title: "Select model", failure: failure)
        try io.type(model)
        guard var dialog = try settled(search: model) else {
            throw failure(loc("The OpenCode dialog was not filtered to '%@'.", model), nil)
        }
        var row = model
        // 걸러진 것이 없다 — 제공자가 하나뿐이라 이름으로만 걸러지는 대화상자일 수 있다. 제공자를 확인한 뒤, 프리셋이 그 제공자의 것이면 이름으로 다시 거른다.
        if dialog.rows.isEmpty, let current, let provider = try soleProvider(current: current, typed: model, failure: failure) {
            let words = model.split(separator: " ").map(String.init)
            let ending = words.suffix(provider.count)
            guard words.count > provider.count, zip(ending, provider).allSatisfy({ OpenCodeScreen.key($0) == OpenCodeScreen.key($1) }) else {
                throw failure(loc("Not chosen: the OpenCode dialog has no row '%@' (top row: %@).", model, loc("no rows")), nil)
            }
            row = words.dropLast(provider.count).joined(separator: " ")
            try io.type(row)
            guard let named = try settled(search: row) else {
                throw failure(loc("The OpenCode dialog was not filtered to '%@'.", row), nil)
            }
            dialog = named
        }
        try choose(row: row, in: dialog, failure: failure)
        // 기억해 둔 variant 가 없는 모델은 variant 대화상자가 이어서 뜬다 — 닫힐 때까지 기다린다(다음 단계가 처리한다).
        guard (try poll(timeoutMs: 3000) { lines in
            if OpenCodeScreen.dialogTitle(lines) == "Select variant" { return true }
            return OpenCodeScreen.dialogTitle(lines) == nil && OpenCodeScreen.status(lines).map { OpenCodeScreen.key($0.model) == OpenCodeScreen.key(model) } == true
        }) != nil else {
            throw failure(loc("The OpenCode model line did not change to '%@'.", model), nil)
        }
    }

    /// 그 모델에 variant 가 없어 아무것도 고르지 못했으면 false.
    private func pickVariant(_ variant: String, failure: (String, String?) -> SlashCommandError) throws -> Bool {
        let screen = io.freshSnapshot()?.lines ?? []
        // 모델을 고른 뒤 variant 대화상자가 자동으로 떠 있으면 그것을 쓰고, 아니면 이미 그 값인지 보고 필요할 때만 연다.
        if OpenCodeScreen.dialogTitle(screen) != "Select variant" {
            if OpenCodeScreen.status(screen)?.variant.map({ OpenCodeScreen.key($0) }) == OpenCodeScreen.key(variant) { return true }
            guard try openVariants(failure: failure) else { return false }
        }
        guard let dialog = OpenCodeScreen.dialog(io.freshSnapshot()?.lines ?? []) else { throw failure(loc("Could not read the OpenCode variant dialog."), nil) }
        guard let wanted = dialog.rows.first(where: { OpenCodeScreen.key($0.text) == OpenCodeScreen.key(variant) }) else {
            throw failure(loc("This OpenCode model has no variant '%@' (%@).", variant, dialog.rows.map(\.text).joined(separator: ", ")), nil)
        }
        if wanted.current { try io.press(.escape); return true }
        try chooseInOpenDialog(text: wanted.text, failure: failure)
        return true
    }

    /// `model` 을 주면 입력 상자의 모델 줄이 그 모델일 때만 성공이다 — 대화상자에서 행을 «세어서» 골랐으므로 결과를 글자로 확인한다.
    private func finish(before: DefaultsSnapshot?, model: String?, failure: (String, String?) -> SlashCommandError) throws -> Outcome {
        guard let lines = try poll(timeoutMs: 4000, { OpenCodeScreen.idle($0) }), let status = OpenCodeScreen.status(lines) else {
            throw failure(loc("Stopped: the OpenCode input box did not come back."), nil)
        }
        if let model, OpenCodeScreen.key(status.model) != OpenCodeScreen.key(model) {
            throw failure(loc("The OpenCode model line did not change to '%@'.", model), nil)
        }
        var warning: String?
        if let before {
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
            sleep(250)
            if case .failed(let reason) = defaults.restore(to: before) { warning = loc("Could not put back the default for new sessions: %@", reason) }
        }
        return Outcome(confirmations: ["Using \(status.model)" + (status.variant.map { " · \($0)" } ?? "")], warning: warning)
    }
}
