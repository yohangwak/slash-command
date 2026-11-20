import XCTest
@testable import SlashCommandCore

#if canImport(CryptoKit)
final class OrcaChatDriverTests: XCTestCase {
    private let preset = AgentPreset(model: "fable", effort: "Extra high")

    private func options(model: String? = nil, effort: String? = nil,
                         sources: [String: String] = [:]) -> [String: Any] {
        let models: [[String: Any]] = [
            ["id": "sonnet", "label": "Sonnet", "isDefault": true,
             "efforts": [["label": "High", "value": "high"], ["label": "Extra high", "value": "xhigh"]]],
            ["id": "claude-fable-5-1[1m]", "label": "Fable", "isDefault": false,
             "efforts": [["label": "High", "value": "high"], ["label": "Extra high", "value": "xhigh"]]],
        ]
        var current: [String: Any] = ["acceptedInputSources": sources]
        if let model { current["model"] = model }
        if let effort { current["effort"] = effort }
        return ["models": models, "current": current]
    }

    func testWritesBothOptionsWhenEffortWasAlreadySavedBeforeChangingModel() throws {
        let initial = options(model: "sonnet", effort: "xhigh", sources: ["model": "saved", "effort": "saved"])
        let saved = options(model: "claude-fable-5-1[1m]", effort: "xhigh", sources: ["model": "saved", "effort": "saved"])
        var requests: [(String, NSDictionary)] = []
        var ids = [UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!,
                   UUID(uuidString: "FEDCBA98-7654-3210-FEDC-BA9876543210")!]
        let driver = OrcaChatDriver(sessionID: "s-1", call: { method, params in
            requests.append((method, params as NSDictionary))
            if method == "agentSession.options" { return .success(requests.count == 1 ? initial : saved) }
            return .success(["ok": true, "replayed": false, "value": ["options": saved]])
        }, now: { Date(timeIntervalSince1970: 1_795_136_000.125) }, uuid: { ids.isEmpty ? UUID() : ids.removeFirst() })

        let outcome = try driver.apply(preset)
        XCTAssertEqual(outcome.modelLabel, "Fable")
        XCTAssertEqual(outcome.effortLabel, "Extra high")
        XCTAssertEqual(requests.map { $0.0 }, ["agentSession.options", "agentSession.setOption", "agentSession.setOption", "agentSession.options"])
        let read = ["sessionId": "s-1"] as NSDictionary
        let model = [
            "key": "model", "value": "claude-fable-5-1[1m]",
            "envelope": ["sessionId": "s-1", "clientOperationId": "1795136000125-0123456789abcdef0123456789abcdef",
                         "expectedRuntimeFence": NSNull(), "payloadFingerprint": "60b7f7e78c3ce9698c0b7577eb370288bd626e5586f66b1898d295233da81b0c"],
        ] as NSDictionary
        let effort = [
            "key": "effort", "value": "xhigh",
            "envelope": ["sessionId": "s-1", "clientOperationId": "1795136000125-fedcba9876543210fedcba9876543210",
                         "expectedRuntimeFence": NSNull(), "payloadFingerprint": "259e48f928e5f2020ddf556acb817601f6f238a4a0616017a1585f5d2008dc18"],
        ] as NSDictionary
        XCTAssertEqual(requests.map { $0.1 }, [read, model, effort, read])
    }

    func testRefusedModelStopsBeforeWritingEffort() {
        var writes: [String] = []
        let driver = OrcaChatDriver(sessionID: "s-1", call: { method, params in
            if method == "agentSession.options" { return .success(self.options()) }
            writes.append(params["key"] as? String ?? "")
            return .success(["ok": false, "refusal": ["code": "refused", "message": "raw runtime text"]])
        })
        XCTAssertThrowsError(try driver.apply(preset)) { error in
            XCTAssertFalse(String(describing: error).contains("raw runtime text"))
        }
        XCTAssertEqual(writes, ["model"])
    }

    func testMissingModelOrEffortIsRefusedBeforeAnyWrite() {
        var methods: [String] = []
        let driver = OrcaChatDriver(sessionID: "s-1", call: { method, _ in
            methods.append(method)
            return .success(self.options())
        })
        XCTAssertThrowsError(try driver.apply(.init(model: "haiku", effort: "high")))
        XCTAssertThrowsError(try driver.apply(.init(model: "sonnet", effort: "low")))
        XCTAssertEqual(methods, ["agentSession.options", "agentSession.options"])
    }

    func testAnAcceptedWriteWithoutSavedReadbackIsNotSuccess() {
        var reads = 0
        var writes: [String] = []
        let driver = OrcaChatDriver(sessionID: "s-1", call: { method, params in
            if method == "agentSession.options" {
                reads += 1
                return .success(reads == 1 ? self.options() : self.options(
                    model: "claude-fable-5-1[1m]", effort: "xhigh", sources: ["model": "saved", "effort": "default"]))
            }
            writes.append(params["key"] as? String ?? "")
            return .success(["ok": true])
        })
        XCTAssertThrowsError(try driver.apply(preset))
        XCTAssertEqual(writes, ["model", "effort"])
    }

    func testEffortStepChangesOnlyTheSavedEffortAndStopsAtTheEdge() throws {
        var effort = "high"
        var changes: [String] = []
        let driver = OrcaChatDriver(sessionID: "s-1", call: { method, params in
            if method == "agentSession.options" {
                return .success(self.options(model: "claude-fable-5-1[1m]", effort: effort, sources: ["model": "saved", "effort": "saved"]))
            }
            effort = params["value"] as? String ?? ""
            changes.append("\(params["key"] as? String ?? "")=\(effort)")
            return .success(["ok": true])
        })
        XCTAssertEqual(try driver.stepEffort(up: true).effortLabel, "Extra high")
        XCTAssertThrowsError(try driver.stepEffort(up: true)) { error in
            XCTAssertEqual((error as? SlashCommandError)?.nothingToDo, true)
        }
        XCTAssertEqual(changes, ["effort=xhigh"])
    }
}
#endif
