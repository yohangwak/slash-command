import AppKit
import ModelSwitchCore
import SwiftUI

/// 편집 화면용 프리셋 한 줄. 에이전트별 설정을 켜고 끌 수 있게 옵셔널을 풀어 둔다.
struct EditableSlot: Identifiable {
    let id = UUID()
    var name: String
    var claudeOn: Bool
    var claudeModel: String
    var claudeEffort: String
    var codexOn: Bool
    var codexModel: String
    var codexEffort: String
    var grokOn: Bool
    var grokModel: String
    var grokEffort: String
    var cursorOn: Bool
    var cursorModel: String
    var cursorEffort: String
    var antigravityOn: Bool
    var antigravityModel: String
    var antigravityEffort: String
    var opencodeOn: Bool
    var opencodeModel: String
    var opencodeEffort: String

    init(_ slot: Slot) {
        name = slot.name
        claudeOn = slot.claude != nil
        claudeModel = slot.claude?.model ?? "opus"
        claudeEffort = slot.claude?.effort ?? "high"
        codexOn = slot.codex != nil
        codexModel = slot.codex?.model ?? ""
        codexEffort = slot.codex?.effort ?? "high"
        grokOn = slot.grok != nil
        grokModel = slot.grok?.model ?? ""
        grokEffort = slot.grok?.effort ?? "high"
        cursorOn = slot.cursor != nil
        cursorModel = slot.cursor?.model ?? ""
        cursorEffort = slot.cursor?.effort ?? "high"
        antigravityOn = slot.antigravity != nil
        antigravityModel = slot.antigravity?.model ?? ""
        antigravityEffort = slot.antigravity?.effort ?? "high"
        opencodeOn = slot.opencode != nil
        opencodeModel = slot.opencode?.model ?? ""
        opencodeEffort = slot.opencode?.effort ?? "high"
    }

    var slot: Slot {
        Slot(name: name.trimmingCharacters(in: .whitespaces),
             claude: claudeOn ? AgentPreset(model: claudeModel.trimmingCharacters(in: .whitespaces), effort: claudeEffort) : nil,
             codex: codexOn ? AgentPreset(model: codexModel.trimmingCharacters(in: .whitespaces), effort: codexEffort) : nil,
             grok: grokOn ? AgentPreset(model: grokModel.trimmingCharacters(in: .whitespaces), effort: grokEffort) : nil,
             cursor: cursorOn ? AgentPreset(model: cursorModel.trimmingCharacters(in: .whitespaces), effort: cursorEffort) : nil,
             antigravity: antigravityOn ? AgentPreset(model: antigravityModel.trimmingCharacters(in: .whitespaces), effort: antigravityEffort) : nil,
             opencode: opencodeOn ? AgentPreset(model: opencodeModel.trimmingCharacters(in: .whitespaces), effort: opencodeEffort) : nil)
    }
}

final class SettingsModel: ObservableObject {
    @Published var slots: [EditableSlot] = []
    @Published var keepDefaults = true
    @Published var acceptSwitchPrompt = true
    @Published var effortKeys = true
    @Published var modifiers: Set<String> = Set(ModelSwitchConfig.defaultModifiers)
    @Published var status = ""

    let store: ConfigStore
    let onSaved: () -> Void
    let codexModels: [String]
    let grokModels: [String]

    static let claudeModels = ["fable", "opus", "sonnet", "haiku"]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let codexEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
    static let grokEfforts = ["low", "medium", "high", "xhigh"]
    static let cursorModels = ["Grok 4.7", "Claude Opus 5.5", "Claude Fable 5.1", "GPT-5.6 Sol", "Composer 2.5"]
    static let cursorEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let antigravityModels = ["Gemini 3.8 Flash", "Gemini 3.7 Flash", "Gemini 3.6 Flash", "Gemini 3.1 Pro", "Claude Opus 5.5", "Claude Sonnet 5.5"]
    static let antigravityEfforts = ["low", "medium", "high"]
    static let opencodeEfforts = ["Default", "low", "medium", "high", "max"]

    init(store: ConfigStore, onSaved: @escaping () -> Void) {
        self.store = store
        self.onSaved = onSaved
        codexModels = (try? CodexModels.load().listed.map(\.slug)) ?? []
        grokModels = GrokModels.load().models.map(\.id)
        reload()
    }

    var symbols: String {
        ModelSwitchConfig(modifiers: ModelSwitchConfig.knownModifiers.filter(modifiers.contains), slots: []).modifierSymbols
    }

    func reload() {
        do {
            let config = try store.load()
            slots = config.slots.map(EditableSlot.init)
            keepDefaults = config.keepDefaults
            acceptSwitchPrompt = config.acceptSwitchPrompt
            effortKeys = config.effortKeys
            modifiers = Set(config.modifiers)
            status = ""
        } catch {
            status = "\(error)"
        }
    }

    func add() {
        guard slots.count < ModelSwitchConfig.maxSlots else { return }
        var slot = EditableSlot(Slot(claude: AgentPreset(model: "opus", effort: "high")))
        slot.codexModel = codexModels.first ?? ""
        slot.grokModel = grokModels.first ?? ""
        slots.append(slot)
    }

    func save() {
        for (index, slot) in slots.enumerated() {
            if slot.claudeOn && slot.claudeModel.trimmingCharacters(in: .whitespaces).isEmpty
                || slot.codexOn && slot.codexModel.trimmingCharacters(in: .whitespaces).isEmpty
                || slot.grokOn && slot.grokModel.trimmingCharacters(in: .whitespaces).isEmpty
                || slot.cursorOn && slot.cursorModel.trimmingCharacters(in: .whitespaces).isEmpty
                || slot.antigravityOn && slot.antigravityModel.trimmingCharacters(in: .whitespaces).isEmpty
                || slot.opencodeOn && slot.opencodeModel.trimmingCharacters(in: .whitespaces).isEmpty {
                status = "\(index + 1)번 프리셋의 모델이 비어 있습니다."
                return
            }
        }
        guard !modifiers.isEmpty else {
            status = "단축키 조합 키를 하나 이상 골라 주세요."
            return
        }
        do {
            try store.save(ModelSwitchConfig(keepDefaults: keepDefaults,
                                      acceptSwitchPrompt: acceptSwitchPrompt,
                                      effortKeys: effortKeys,
                                      modifiers: ModelSwitchConfig.knownModifiers.filter(modifiers.contains),
                                      slots: slots.map(\.slot)))
            status = "저장했습니다."
            onSaved()
        } catch {
            status = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionsBox(model: permissions)

            Text("프리셋").font(.title2.weight(.semibold))
            Text("Ghostty·Orca·iTerm2 터미널에서 \(model.symbols)번호를 누르면, 맨 앞 세션이 claude·codex·grok·cursor·agy·opencode 중 무엇인지에 맞춰 그 번호의 모델과 effort 로 바꿉니다.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, _ in
                        SlotRow(shortcut: "\(model.symbols)\(index + 1)", slot: $model.slots[index], codexModels: model.codexModels, grokModels: model.grokModels) {
                            model.slots.remove(at: index)
                        }
                    }
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("프리셋 추가") { model.add() }
                    .disabled(model.slots.count >= ModelSwitchConfig.maxSlots)
                Spacer()
            }

            HStack(spacing: 14) {
                Text("단축키")
                ForEach([("control", "⌃ Control"), ("option", "⌥ Option"), ("shift", "⇧ Shift"), ("command", "⌘ Command")], id: \.0) { key, label in
                    Toggle(label, isOn: Binding(
                        get: { model.modifiers.contains(key) },
                        set: { on in if on { model.modifiers.insert(key) } else { model.modifiers.remove(key) } }))
                }
                Text("+ 번호").foregroundStyle(.secondary)
            }

            Toggle("\(model.symbols)= · \(model.symbols)- 로 effort 만 한 단계 올리고 내린다", isOn: $model.effortKeys)

            Toggle("이 세션만 바꾼다(새 세션 기본값은 그대로)", isOn: $model.keepDefaults)
            Text("켜 두면 claude·codex 선택창에서 「이 세션만」으로 확정합니다. 끄면 claude 는 새로 여는 세션의 기본값까지 바뀝니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("claude 의 확인 창(Switch model? · Change effort level?)을 자동으로 받아들인다", isOn: $model.acceptSwitchPrompt)
            Text("claude 는 방금 응답한 대화에서 모델이나 effort 를 바꾸면 대화 기록을 다시 읽는다고 알리고 한 번 더 묻습니다. 켜 두면 우리가 고른 그 값을 물을 때만 받아들이고, 꺼 두면 그 창에서 직접 Enter 를 눌러야 바뀝니다.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("되돌리기") { model.reload() }
                Button("저장") { model.save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

private struct SlotRow: View {
    let shortcut: String
    @Binding var slot: EditableSlot
    let codexModels: [String]
    let grokModels: [String]
    let onDelete: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(shortcut).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    TextField("이름(선택)", text: $slot.name).textFieldStyle(.roundedBorder).frame(width: 180)
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("이 프리셋 삭제")
                }
                AgentRow(label: "claude", isOn: $slot.claudeOn, model: $slot.claudeModel, effort: $slot.claudeEffort,
                         models: SettingsModel.claudeModels, efforts: SettingsModel.claudeEfforts)
                AgentRow(label: "codex", isOn: $slot.codexOn, model: $slot.codexModel, effort: $slot.codexEffort,
                         models: codexModels, efforts: SettingsModel.codexEfforts)
                AgentRow(label: "grok", isOn: $slot.grokOn, model: $slot.grokModel, effort: $slot.grokEffort,
                         models: grokModels, efforts: SettingsModel.grokEfforts)
                AgentRow(label: "cursor", isOn: $slot.cursorOn, model: $slot.cursorModel, effort: $slot.cursorEffort,
                         models: SettingsModel.cursorModels, efforts: SettingsModel.cursorEfforts)
                AgentRow(label: "agy", isOn: $slot.antigravityOn, model: $slot.antigravityModel, effort: $slot.antigravityEffort,
                         models: SettingsModel.antigravityModels, efforts: SettingsModel.antigravityEfforts)
                AgentRow(label: "opencode", isOn: $slot.opencodeOn, model: $slot.opencodeModel, effort: $slot.opencodeEffort,
                         models: [], efforts: SettingsModel.opencodeEfforts)
            }
            .padding(4)
        }
    }
}

private struct AgentRow: View {
    let label: String
    @Binding var isOn: Bool
    @Binding var model: String
    @Binding var effort: String
    let models: [String]
    let efforts: [String]

    var body: some View {
        HStack {
            Toggle(label, isOn: $isOn).frame(width: 80, alignment: .leading)
            HStack {
                TextField("모델", text: $model).textFieldStyle(.roundedBorder).frame(width: 200)
                Menu("고르기") {
                    ForEach(models, id: \.self) { name in Button(name) { model = name } }
                }
                .frame(width: 80)
                Picker("effort", selection: $effort) {
                    ForEach(efforts.contains(effort) ? efforts : efforts + [effort], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            .disabled(!isOn)
            .opacity(isOn ? 1 : 0.45)
            Spacer()
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: SettingsModel
    private let permissions = PermissionsModel()
    private var window: NSWindow?

    init(store: ConfigStore, onSaved: @escaping () -> Void) {
        model = SettingsModel(store: store, onSaved: onSaved)
    }

    /// 창이 닫히면 권한 상태를 다시 읽는 것을 멈춘다.
    func windowWillClose(_ notification: Notification) {
        permissions.stop()
    }

    func present() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, permissions: permissions)))
            window.title = "ModelSwitch"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.reload()
        permissions.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
