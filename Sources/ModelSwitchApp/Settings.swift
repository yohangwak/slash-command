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

    init(_ slot: Slot) {
        name = slot.name
        claudeOn = slot.claude != nil
        claudeModel = slot.claude?.model ?? "opus"
        claudeEffort = slot.claude?.effort ?? "high"
        codexOn = slot.codex != nil
        codexModel = slot.codex?.model ?? ""
        codexEffort = slot.codex?.effort ?? "high"
    }

    var slot: Slot {
        Slot(name: name.trimmingCharacters(in: .whitespaces),
             claude: claudeOn ? AgentPreset(model: claudeModel.trimmingCharacters(in: .whitespaces), effort: claudeEffort) : nil,
             codex: codexOn ? AgentPreset(model: codexModel.trimmingCharacters(in: .whitespaces), effort: codexEffort) : nil)
    }
}

final class SettingsModel: ObservableObject {
    @Published var slots: [EditableSlot] = []
    @Published var keepDefaults = true
    @Published var acceptSwitchPrompt = false
    @Published var effortKeys = true
    @Published var modifiers: Set<String> = Set(ModelSwitchConfig.defaultModifiers)
    @Published var status = ""

    let store: ConfigStore
    let onSaved: () -> Void
    let codexModels: [String]

    static let claudeModels = ["fable", "opus", "sonnet", "haiku"]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    static let codexEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    init(store: ConfigStore, onSaved: @escaping () -> Void) {
        self.store = store
        self.onSaved = onSaved
        codexModels = (try? CodexModels.load().listed.map(\.slug)) ?? []
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
        slots.append(slot)
    }

    func save() {
        for (index, slot) in slots.enumerated() {
            if slot.claudeOn && slot.claudeModel.trimmingCharacters(in: .whitespaces).isEmpty
                || slot.codexOn && slot.codexModel.trimmingCharacters(in: .whitespaces).isEmpty {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("프리셋").font(.title2.weight(.semibold))
            Text("Ghostty·Orca 터미널에서 \(model.symbols)번호를 누르면, 맨 앞 세션이 claude 인지 codex 인지에 맞춰 그 번호의 모델과 effort 로 바꿉니다.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, _ in
                        SlotRow(shortcut: "\(model.symbols)\(index + 1)", slot: $model.slots[index], codexModels: model.codexModels) {
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

            Toggle("claude 의 「Switch model?」 확인 창을 자동으로 받아들인다", isOn: $model.acceptSwitchPrompt)
            Text("claude 는 대화 도중 모델을 바꾸면 대화 기록을 새 모델로 다시 읽는다고 알리고 한 번 더 묻습니다. 꺼 두면 그 창에서 직접 Enter 를 눌러야 바뀝니다.")
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
    private var window: NSWindow?

    init(store: ConfigStore, onSaved: @escaping () -> Void) {
        model = SettingsModel(store: store, onSaved: onSaved)
    }

    func present() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "ModelSwitch"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
