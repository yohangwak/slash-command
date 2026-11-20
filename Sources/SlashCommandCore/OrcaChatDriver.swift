import Foundation

/// Changes the selected Orca chat's options for its next message.
struct OrcaChatDriver {
    typealias Call = (String, [String: Any]) -> Result<[String: Any], OrcaRuntime.Failure>

    struct Outcome: Equatable, Sendable {
        let modelLabel: String
        let effortLabel: String?

        var summary: String { [modelLabel, effortLabel].compactMap { $0 }.joined(separator: " · ") }
        var detail: String { loc("Takes effect from your next message in this chat.") }
        var confirmations: [String] { [summary, detail] }
    }

    let sessionID: String
    let call: Call
    let now: () -> Date
    let uuid: () -> UUID

    init(sessionID: String, call: @escaping Call = { OrcaRuntime.call($0, $1) },
         now: @escaping () -> Date = Date.init, uuid: @escaping () -> UUID = UUID.init) {
        self.sessionID = sessionID
        self.call = call
        self.now = now
        self.uuid = uuid
    }

    func apply(_ preset: AgentPreset) throws -> Outcome {
        let initial = try readOptions()
        let changeModel = !preset.model.trimmingCharacters(in: .whitespaces).isEmpty
        let model: OrcaChatOptions.Model
        if changeModel {
            guard case .found(let offered) = initial.model(for: preset.model) else {
                throw SlashCommandError(loc("Not switched: this Orca chat does not offer the model %@.", preset.model))
            }
            model = offered
        } else {
            model = try currentModel(in: initial)
        }
        var effort: OrcaChatOptions.Effort?
        if !preset.effort.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let value = OrcaChatOptions.effort(preset.effort, in: model),
                  let offered = model.efforts.first(where: { $0.value == value }) else {
                throw SlashCommandError(loc("Not switched: this Orca chat model does not offer the effort %@.", preset.effort))
            }
            effort = offered
        }
        return try change(initial, model: model, changeModel: changeModel, effort: effort)
    }

    func stepEffort(up: Bool) throws -> Outcome {
        let initial = try readOptions()
        let model = try currentModel(in: initial)
        guard initial.holds(key: "model", value: model.id), let value = initial.currentEffort,
              initial.holds(key: "effort", value: value) else { throw unknownEffort }
        let matches = model.efforts.filter { $0.value == value }
        guard matches.count == 1, let current = matches.first else { throw unknownEffort }
        guard let next = OrcaChatOptions.neighbor(of: value, up: up, in: model) else {
            var error = SlashCommandError(up ? loc("Already at the highest level (%@).", current.label)
                                             : loc("Already at the lowest level (%@).", current.label))
            error.nothingToDo = true
            throw error.quotingOutput([current.label])
        }
        let neighbors = model.efforts.filter { $0.value == next }
        guard neighbors.count == 1, let effort = neighbors.first else { throw unknownEffort }
        return try change(initial, model: model, changeModel: false, effort: effort)
    }

    private func options() -> OrcaChatOptions.Options? {
        guard case .success(let result) = call("agentSession.options", ["sessionId": sessionID]) else { return nil }
        return OrcaChatOptions.parse(result)
    }

    private func readOptions() throws -> OrcaChatOptions.Options {
        guard let options = options() else {
            throw SlashCommandError(loc("Not switched: could not read this Orca chat's options."))
        }
        return options
    }

    private func currentModel(in options: OrcaChatOptions.Options) throws -> OrcaChatOptions.Model {
        let matches = options.models.filter { $0.id == options.currentModel }
        guard matches.count == 1, let model = matches.first else {
            throw SlashCommandError(loc("Not switched: the current model of this Orca chat is unknown."))
        }
        return model
    }

    private var unknownEffort: SlashCommandError {
        SlashCommandError(loc("Not switched: this Orca chat needs a saved model and effort. Choose both in the chat first."))
    }

    private func change(_ initial: OrcaChatOptions.Options, model: OrcaChatOptions.Model,
                        changeModel: Bool, effort: OrcaChatOptions.Effort?) throws -> Outcome {
        let writeModel = changeModel && !initial.holds(key: "model", value: model.id)
        let writeEffort = effort.map { writeModel || !initial.holds(key: "effort", value: $0.value) } ?? false
        let unconfirmed = SlashCommandError(loc("Could not confirm the change to this Orca chat."))
        let partial = SlashCommandError(loc("Orca set the chat model. The effort change could not be confirmed."))
        if writeModel, try !set("model", to: model.id) { throw unconfirmed }
        if writeEffort, let effort, try !set("effort", to: effort.value) {
            throw writeModel ? partial : unconfirmed
        }
        if writeModel || writeEffort {
            let readback = options()
            let modelVerified = changeModel ? readback?.holds(key: "model", value: model.id) == true
                                            : readback?.currentModel == model.id
            let effortVerified = effort.map { readback?.holds(key: "effort", value: $0.value) == true } ?? true
            guard modelVerified, effortVerified else {
                if writeModel, modelVerified { throw partial }
                throw SlashCommandError(loc("Orca accepted the chat changes. The saved values could not be verified."))
            }
        }
        return Outcome(modelLabel: model.label, effortLabel: effort?.label)
    }

    private func set(_ key: String, to value: String) throws -> Bool {
        #if canImport(CryptoKit)
        let operationID = OrcaChatOptions.operationID(now: now(), entropy: uuid())
        let params = OrcaChatOptions.setOptionParams(sessionID: sessionID, key: key, value: value, operationID: operationID)
        guard case .success(let result) = call("agentSession.setOption", params) else { return false }
        return OrcaChatOptions.accepted(result)
        #else
        throw SlashCommandError(loc("This is not supported on this operating system yet."))
        #endif
    }
}
