import XCTest
import SlashCommandCore

final class OrcaChatOptionsTests: XCTestCase {
    func testParsesCatalogAndSavedOptionsBeforeAnyConfirmedTurn() throws {
        let models: [[String: Any]] = [
            ["id": "opus", "label": "Opus", "efforts": [["value": "low", "label": "Low"], ["value": "high", "label": "High"]], "isDefault": true],
            ["id": "haiku", "label": "Haiku", "efforts": []],
        ]
        let options = try XCTUnwrap(OrcaChatOptions.parse([
            "models": models,
            "current": ["model": "opus", "effort": "high", "acceptedInputSources": ["model": "saved", "effort": "default"]],
        ]))
        XCTAssertEqual(options.models, [
            .init(id: "opus", label: "Opus", efforts: [.init(value: "low", label: "Low"), .init(value: "high", label: "High")]),
            .init(id: "haiku", label: "Haiku", efforts: []),
        ])
        XCTAssertEqual(options.currentModel, "opus")
        XCTAssertEqual(options.currentEffort, "high")
        XCTAssertTrue(options.holds(key: "model", value: "opus"))
        XCTAssertFalse(options.holds(key: "model", value: "haiku"))
        XCTAssertFalse(options.holds(key: "effort", value: "high"))

        let unreported = try XCTUnwrap(OrcaChatOptions.parse(["models": models, "current": [:]]))
        XCTAssertNil(unreported.currentModel)
        XCTAssertNil(unreported.currentEffort)
    }

    func testRejectsMalformedModelsOrCurrentOptions() {
        let current: [String: Any] = ["model": "opus"]
        XCTAssertNil(OrcaChatOptions.parse(["models": "opus", "current": current]))
        XCTAssertNil(OrcaChatOptions.parse(["models": ["opus"], "current": current]))
        XCTAssertNil(OrcaChatOptions.parse(["models": [["id": "opus"], ["label": "Haiku"]], "current": current]))
        XCTAssertNil(OrcaChatOptions.parse(["models": [["id": ""]], "current": current]))
        XCTAssertNil(OrcaChatOptions.parse(["models": [["id": 6]], "current": current]))
        XCTAssertNil(OrcaChatOptions.parse(["models": [["id": "opus"]], "current": NSNull()]))
        XCTAssertNil(OrcaChatOptions.parse(["models": [["id": "opus", "label": "Opus", "efforts": [["label": "High"]]]], "current": current]))
    }

    func testParsesModelsWithoutEffortsAndKeepsStringSources() throws {
        let models: [[String: Any]] = [["id": "haiku"], ["id": "sonnet", "label": "", "efforts": NSNull()]]
        let sources: [String: Any] = ["model": "saved", "effort": NSNull(), "mode": false]
        let options = try XCTUnwrap(OrcaChatOptions.parse([
            "models": models,
            "current": ["model": "haiku", "acceptedInputSources": sources],
        ]))
        XCTAssertEqual(options.models, [.init(id: "haiku", label: "haiku", efforts: []),
                                        .init(id: "sonnet", label: "sonnet", efforts: [])])
        XCTAssertEqual(options.acceptedSources, ["model": "saved"])
    }

    func testMatchesNormalizedIDsBeforeLabels() throws {
        let options = try XCTUnwrap(OrcaChatOptions.parse([
            "models": [
                ["id": "gpt-6", "label": "Codex 6", "efforts": []],
                ["id": "opus", "label": "GPT 6", "efforts": []],
                ["id": "claude-opus", "label": "Claude", "efforts": []],
                ["id": "CLAUDE OPUS", "label": "Claude!", "efforts": []],
                ["id": "haiku", "label": "Claude Opus", "efforts": []],
            ] as [[String: Any]],
            "current": ["model": "gpt-6"],
        ]))

        let codex = OrcaChatOptions.Model(id: "gpt-6", label: "Codex 6", efforts: [])
        XCTAssertEqual(options.model(for: "GPT 6"), .found(codex))
        XCTAssertEqual(options.model(for: "  CODEX-6 "), .found(codex))
        XCTAssertEqual(options.model(for: "claude opus"), .ambiguous)
        XCTAssertEqual(options.model(for: "claude"), .ambiguous)
        XCTAssertEqual(options.model(for: "sonnet"), .missing)
    }

    func testMatchesEffortsAndStepsWithoutWrapping() {
        let model = OrcaChatOptions.Model(id: "opus", label: "Opus", efforts: [
            .init(value: "low", label: "Low"), .init(value: "high", label: "High"), .init(value: "xhigh", label: "Extra high"),
        ])
        XCTAssertEqual(OrcaChatOptions.effort(" EXTRA HIGH ", in: model), "xhigh")
        XCTAssertEqual(OrcaChatOptions.effort("XHIGH", in: model), "xhigh")
        XCTAssertNil(OrcaChatOptions.effort("medium", in: model))
        let ambiguous = OrcaChatOptions.Model(id: "opus", label: "Opus", efforts: [
            .init(value: "high", label: "Extra-High"), .init(value: "xhigh", label: "extra high"),
            .init(value: "max", label: "High"),
        ])
        XCTAssertNil(OrcaChatOptions.effort("extra high", in: ambiguous))
        XCTAssertEqual(OrcaChatOptions.effort("high", in: ambiguous), "high")

        XCTAssertEqual(OrcaChatOptions.neighbor(of: "high", up: true, in: model), "xhigh")
        XCTAssertEqual(OrcaChatOptions.neighbor(of: "high", up: false, in: model), "low")
        XCTAssertNil(OrcaChatOptions.neighbor(of: "xhigh", up: true, in: model))
        XCTAssertNil(OrcaChatOptions.neighbor(of: "low", up: false, in: model))
        XCTAssertNil(OrcaChatOptions.neighbor(of: "medium", up: true, in: model))
    }

    func testBuildsSetOptionParamsWithCanonicalFingerprint() throws {
        #if canImport(CryptoKit)
        let expected = "ab4d99b56a5a1398f29e083db6c6ab1e4f00016a035f72dd7129ae3dbf7bd807"
        #else
        let expected = ""
        #endif
        XCTAssertEqual(OrcaChatOptions.fingerprint(sessionID: "s-1", key: "model", value: "opus"), expected)
        let params = OrcaChatOptions.setOptionParams(sessionID: "s-1", key: "model", value: "opus", operationID: "op-2")
        XCTAssertEqual(params["key"] as? String, "model")
        XCTAssertEqual(params["value"] as? String, "opus")
        let envelope = try XCTUnwrap(params["envelope"] as? [String: Any])
        XCTAssertEqual(envelope["sessionId"] as? String, "s-1")
        XCTAssertEqual(envelope["clientOperationId"] as? String, "op-2")
        XCTAssertTrue(envelope["expectedRuntimeFence"] is NSNull)
        XCTAssertEqual(envelope["payloadFingerprint"] as? String, expected)
    }

    #if canImport(CryptoKit)
    func testFingerprintUsesJavaScriptStringEscaping() {
        XCTAssertEqual(OrcaChatOptions.fingerprint(sessionID: "s-1", key: "effort", value: "a\"b 한"),
                       "e1c16f45827bc472776f0ba6d51b3d351d9bd397672eb33970c2600b2ad80554")
        let value = "\u{08}\u{0C}\n\r\t\u{00}\u{1F}\\/\u{2028}\u{2029}🦊e\u{0301}"
        XCTAssertEqual(OrcaChatOptions.fingerprint(sessionID: "s-1", key: "effort", value: value),
                       "dda649f68665b20d71bfa8f8d223fe5b0907c080446133eb580b98754815cdf8")
    }
    #endif
}
