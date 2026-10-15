import AppKit
import ApplicationServices
import Foundation
import SlashCommandCore

/// A test tool that measures how far the signals Orca gives for "the terminal currently visible" lag behind the UI (it sends nothing).
/// Run it while a person switches tabs and workspaces in Orca; it stamps when each signal changed, on the same clock.
///   - click: when the left mouse button was pressed (no permission needed)
///   - AX: when Orca's "focused element" and its parent chain changed
///   - DB: when the active workspace and tab in the state DB changed
///   - list: when the per-workspace active tab in the socket's `terminal.list` changed
enum OrcaProbe {
    static func run(seconds: Double) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Detector.orcaBundleID }) else {
            print("Orca is not running"); return
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let start = Date()
        func stamp() -> String { String(format: "+%6.3fs", Date().timeIntervalSince(start)) }
        print("Recording for \(Int(seconds)) seconds. Go to Orca now and switch tabs and workspaces a few times (by click and by shortcut).")

        var lastChain = "", lastDB = "", lastList = ""
        var lastClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        var lastTick = Date.distantPast
        while Date().timeIntervalSince(start) < seconds {
            let click = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
            if click < lastClick { print("\(stamp()) click  (front app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"))") }
            lastClick = click

            let chain = focusChain(element)
            if chain != lastChain { print("\(stamp()) AX     \(chain.isEmpty ? "(no focus)" : chain)"); lastChain = chain }

            if Date().timeIntervalSince(lastTick) > 0.3 {
                lastTick = Date()
                let db = (try? OrcaState.active()).map { "\($0.worktreeID.suffix(28)) tab=\($0.tabID.prefix(8))" } ?? "(unreadable)"
                if db != lastDB { print("\(stamp()) DB     \(db)"); lastDB = db }
                let list = activeTabs()
                if list != lastList { print("\(stamp()) list   \(list)"); lastList = list }
            }
            usleep(20_000)
        }
        print("done")
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// One short line walking up from the focused element, giving role, DOM id, class and title.
    static func focusChain(_ app: AXUIElement) -> String {
        guard let focused = attribute(app, "AXFocusedUIElement") else { return "" }
        var parts: [String] = []
        var current: AXUIElement? = (focused as! AXUIElement)
        var depth = 0
        while let element = current, depth < 8 {
            let role = (attribute(element, "AXRole") as? String ?? "?").replacingOccurrences(of: "AX", with: "")
            let id = attribute(element, "AXDOMIdentifier") as? String ?? ""
            let cls = (attribute(element, "AXDOMClassList") as? [String])?.prefix(2).joined(separator: ".") ?? ""
            let title = (attribute(element, "AXTitle") as? String ?? attribute(element, "AXDescription") as? String ?? "").prefix(24)
            parts.append([role, id.isEmpty ? nil : "#\(id)", cls.isEmpty ? nil : ".\(cls)", title.isEmpty ? nil : "\"\(title)\""].compactMap { $0 }.joined())
            current = attribute(element, "AXParent") as! AXUIElement?
            depth += 1
        }
        return parts.joined(separator: " < ")
    }

    /// From terminal.list, collects the active split (leaf) of each tab in the workspace the DB says is active.
    /// Checks whether the list gives "the tab now visible" on its own, and whether split focus changes faster than the DB.
    static func activeTabs() -> String {
        guard case .success(let payload) = OrcaRuntime.call("terminal.list", ["includeVisualLayouts": true]) else { return "(unreadable)" }
        let layouts = payload["visualLayouts"] as? [[String: Any]] ?? []
        var found: [String] = []
        for layout in layouts {
            var keys = layout.keys.filter { $0.lowercased().contains("active") }.sorted().map { "\($0)=\("\(layout[$0] ?? "")".prefix(8))" }
            var stack: [Any] = [layout["root"] as Any]
            while let node = stack.popLast() {
                if let array = node as? [Any] { stack.append(contentsOf: array); continue }
                guard let dict = node as? [String: Any] else { continue }
                if let tabs = dict["tabs"] as? [[String: Any]] {
                    for tab in tabs {
                        let id = "\(tab["tabId"] ?? "")".prefix(6)
                        let leaf = "\(tab["activeLeafId"] ?? "-")".prefix(6)
                        keys.append("\(id):\(leaf)")
                    }
                }
                for (key, value) in dict where key != "tabs" { stack.append(value) }
                for key in dict.keys.filter({ $0.lowercased().contains("active") && $0 != "activeLeafId" }).sorted() { keys.append("\(key)=\("\(dict[key] ?? "")".prefix(8))") }
            }
            found.append("\("\(layout["worktreeId"] ?? "")".suffix(12)){\(keys.sorted().joined(separator: ","))}")
        }
        return found.sorted().joined(separator: " ")
    }
}
