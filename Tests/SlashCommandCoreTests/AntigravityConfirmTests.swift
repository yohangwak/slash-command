import XCTest
@testable import SlashCommandCore

final class AntigravityConfirmTests: KoreanMessagesTestCase {
    private final class ChangedScreenIO: TerminalIO {
        enum Change { case unreadable, approval, wrongCursor }
        let base: FakeAgy
        let change: Change
        let changeAt: Int
        var targetReads = 0
        init(url: URL, change: Change, changeAt: Int) {
            base = FakeAgy(configURL: url)
            self.change = change
            self.changeAt = changeAt
        }
        func type(_ text: String) throws { try base.type(text) }
        func press(_ key: Key) throws { try base.press(key) }
        func screen() -> [String]? { freshSnapshot()?.lines }
        func freshSnapshot() -> ScreenSnapshot? {
            if base.picker && base.cursor == 2 { targetReads += 1 }
            if targetReads >= changeAt {
                switch change {
                case .unreadable: return nil
                case .approval: return ScreenSnapshot(lines: ["Approve this command?", "> Yes", "  No", "Enter to approve · Esc to cancel"], draft: nil)
                case .wrongCursor:
                    base.cursor = 0
                    return base.screen().map { ScreenSnapshot(lines: $0, draft: nil) }
                }
            }
            return base.screen().map { ScreenSnapshot(lines: $0, draft: nil) }
        }
    }

    private func refuses(_ change: ChangedScreenIO.Change, at read: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-confirm-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\"theme\":\"dark\"}".utf8).write(to: url)
        let io = ChangedScreenIO(url: url, change: change, changeAt: read)
        let driver = AntigravityDriver(io: io, sleep: { _ in }, defaults: AntigravityDefaults(url: url), keepDefaults: true)
        XCTAssertThrowsError(try driver.apply(AgentPreset(model: "GPT-OSS 120B (Medium)", effort: "high")))
        XCTAssertEqual(io.base.presses.filter { $0 == .enter }.count, 1, "Only the Enter opening our picker may be sent")
        XCTAssertEqual(io.base.current, 0)
    }

    func testUnreadableScreenAfterMovingCursorIsRefused() throws { try refuses(.unreadable, at: 2) }
    func testUnreadableScreenImmediatelyBeforeConfirmIsRefused() throws { try refuses(.unreadable, at: 3) }
    func testApprovalInsteadOfPickerIsNeverConfirmed() throws { try refuses(.approval, at: 3) }
    func testCursorOnAnotherRowIsNeverConfirmed() throws { try refuses(.wrongCursor, at: 3) }
}
