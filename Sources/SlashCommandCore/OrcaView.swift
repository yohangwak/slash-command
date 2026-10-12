import AppKit
import ApplicationServices
import Foundation

/// Orca 화면에 «지금 보이는» 탭을 접근성(AX)으로 읽어 터미널 목록과 맞춘다.
///
/// 왜: 상태 DB 와 `terminal.list` 의 «활성 탭» 은 UI 보다 1.3~2.5초 늦다(2026-10-07 같은 전환 5회 실측: DB +1.3~1.7초).
/// Orca 의 탭 줄(DOM)은 접근성 트리에 순서대로 있고 활성 탭만 `text-foreground` 클래스를 가진다 — 같은 전환에서 0.25초 안에 따라왔다.
/// 탭 줄의 제목 순서를 `terminal.list` 의 레이아웃(워크스페이스마다 탭 제목 순서)과 맞추면 워크스페이스와 탭이 정해진다.
/// 읽지 못하거나 하나로 정해지지 않으면 `nil` — 부른 쪽이 DB 로 되돌아간다(옛 동작, 지연 위험은 문서화돼 있다).
public enum OrcaView {
    public struct Strip: Equatable, Sendable {
        /// 탭 줄의 제목들(왼쪽부터). 제목이 잘려 있으면 `truncated` 가 참.
        public struct Tab: Equatable, Sendable {
            public let title: String
            public let truncated: Bool
            public let active: Bool

            public init(title: String, truncated: Bool, active: Bool) {
                self.title = title
                self.truncated = truncated
                self.active = active
            }
        }

        public let tabs: [Tab]

        public init(tabs: [Tab]) { self.tabs = tabs }
    }

    public enum Resolution: Equatable, Sendable {
        case tab(OrcaState.Active)
        /// 같은 탭 제목 순서를 가진 워크스페이스가 둘 이상이다.
        case ambiguous([String])
        /// 맞는 워크스페이스가 없다(탭 줄에 터미널이 아닌 탭이 섞였을 수 있다).
        case noMatch
    }

    // MARK: - 맞추기 (순수 함수)

    /// 제목 비교용: 소문자, 글자·숫자가 아닌 것은 한 칸 공백으로(AX 는 `-` 같은 기호를 공백으로 읽어 준다).
    static func normalized(_ text: String) -> String {
        var out = ""
        var lastSpace = true
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    static func titlesMatch(_ listed: String, _ shown: Strip.Tab) -> Bool {
        let a = normalized(listed)
        let b = normalized(shown.title)
        if a == b { return true }
        // 긴 제목은 화면에서 잘린다. 말줄임표(`...`)가 붙어 오면 그 앞부분과 같으면 되고, 2026-10-07 실측으로는 말줄임표 없이
        // 앞부분만 오는 제목도 있다(96자 제목이 «…HANDOFF 2026 10 06» 까지만). 이때는 12자 이상일 때만 앞부분 일치를 인정한다 —
        // 짧은 제목(`initial` 대 `initial 2`)끼리 섞이지 않도록. 어차피 탭 수와 «모든» 탭 제목이 함께 맞아야 한다.
        guard !b.isEmpty, a.hasPrefix(b) else { return false }
        return shown.truncated || b.count >= 12
    }

    /// 탭 줄과 레이아웃(`terminal.list` 의 `visualLayouts`)을 맞춘다. 탭 수와 제목 순서가 모두 같아야 한다.
    /// 후보가 둘 이상이면 «모호» 다 — 늦은 상태 DB 로 고르지 않는다(DB 는 워크스페이스를 바꾼 직후 1.3~2.5초 옛 값이다).
    public static func resolve(strip: Strip, layouts: [[String: Any]]) -> Resolution {
        guard !strip.tabs.isEmpty, let activeIndex = strip.tabs.firstIndex(where: \.active),
              strip.tabs.filter(\.active).count == 1 else { return .noMatch }
        var candidates: [(worktree: String, tabID: String)] = []
        for layout in layouts {
            guard let worktree = layout["worktreeId"] as? String else { continue }
            let tabs = OrcaState.tabs(in: layout["root"])
            guard tabs.count == strip.tabs.count else { continue }
            let same = zip(tabs, strip.tabs).allSatisfy { titlesMatch($0.0["title"] as? String ?? "", $0.1) }
            guard same, let tabID = tabs[activeIndex]["tabId"] as? String else { continue }
            candidates.append((worktree, tabID))
        }
        switch candidates.count {
        case 0: return .noMatch
        case 1: return .tab(OrcaState.Active(worktreeID: candidates[0].worktree, tabID: candidates[0].tabID))
        default:
            return .ambiguous(candidates.map(\.worktree))
        }
    }

    // MARK: - 접근성으로 읽기

    /// 지금 Orca 의 탭 줄. 권한이 없거나 못 읽으면 nil.
    public static func readStrip() -> Strip? {
        guard GhosttyScreen.trusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Detector.orcaBundleID).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium 은 접근성 요청이 있어야 웹 화면(DOM)을 트리에 내놓는다.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = ((attribute(element, "AXWindows") as? [AXUIElement]) ?? []).map(Node.init)
        // 앱 요소는 «이미 본 것» 으로 넣어 둔다 — 창 아래에서 앱 요소가 다시 자식으로 나오는 때가 있다(아래 `tabs(from:…)`).
        let tabs = tabs(from: windows, seen: [Node(element)],
                        label: { (attribute($0.element, "AXTitle") as? String) ?? (attribute($0.element, "AXDescription") as? String) ?? "" },
                        classes: { (attribute($0.element, "AXDOMClassList") as? [String]) ?? [] },
                        children: { ((attribute($0.element, "AXChildren") as? [AXUIElement]) ?? []).map(Node.init) })
        return tabs.flatMap { $0.isEmpty ? nil : Strip(tabs: $0) }
    }

    /// 접근성 요소 하나. 같은 요소인지는 `CFEqual` 로 본다(같은 요소를 다시 받아도 객체는 다르다).
    struct Node: Hashable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
        static func == (a: Node, b: Node) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// 나무를 위에서 아래로, 형제는 차례대로 돌며 탭 버튼을 모은다. 탭 버튼의 안쪽은 보지 않는다.
    ///
    /// 🔴 이 나무는 «나무가 아닐» 때가 있다: Orca 의 창 아래에서 앱 요소가 다시 자식으로 나와 끝없이 이어진다
    /// (2026-10-12 집 맥 실측: `AXApplication > AXApplication > …`, 깊이 6만 5천에서 스택이 넘쳐 프로그램이 죽었다).
    /// 그래서 이미 본 요소로는 다시 들어가지 않고, 깊이와 요소 수에도 상한을 둔다.
    /// 상한에 걸리면 못 본 탭이 있을 수 있으므로 «모른다»(nil)다 — 일부만 읽은 탭 줄로 탭을 짚지 않는다.
    static func tabs<N: Hashable>(from roots: [N], seen: Set<N> = [], maxDepth: Int = 150, maxNodes: Int = 30_000,
                                  label: (N) -> String, classes: (N) -> [String], children: (N) -> [N]) -> [Strip.Tab]? {
        var seen = seen
        var tabs: [Strip.Tab] = []
        var cut = false
        func visit(_ node: N, depth: Int) {
            guard !cut, seen.insert(node).inserted else { return }
            guard depth <= maxDepth, seen.count <= maxNodes else { cut = true; return }
            if let tab = tab(fromLabel: label(node), classes: classes(node)) {
                tabs.append(tab)
                return
            }
            for child in children(node) { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        return cut ? nil : tabs
    }

    /// `"<상태> <제목> Close tab <제목>"` 꼴의 탭 버튼. 제목은 «Close tab » 뒤의 것을 쓴다.
    static func tab(fromLabel label: String, classes: [String]) -> Strip.Tab? {
        guard let range = label.range(of: "Close tab ", options: .backwards) else { return nil }
        var title = String(label[range.upperBound...])
        var truncated = false
        for ellipsis in ["...", "…"] where title.hasSuffix(ellipsis) {
            title = String(title.dropLast(ellipsis.count))
            truncated = true
        }
        // 활성 탭만 `text-foreground`(그대로) 클래스를 가진다. 나머지는 `text-muted-foreground`·`hover:text-foreground`.
        return Strip.Tab(title: title, truncated: truncated, active: classes.contains("text-foreground"))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
