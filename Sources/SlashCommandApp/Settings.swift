import AppKit
import ServiceManagement
import SlashCommandCore
import SwiftUI

/// 에이전트마다 고를 수 있는 모델·effort 목록. 편집 화면의 제안일 뿐이다 — 모델은 직접 쳐 넣어도 된다.
struct AgentCatalog {
    let codexModels: [String]
    let grokModels: [String]

    static let claudeModels = ["fable", "opus", "sonnet", "haiku"]
    static let cursorModels = ["Grok 4.7", "Claude Opus 5.5", "Claude Fable 5.1", "GPT-5.6 Sol", "Composer 2.5"]
    static let antigravityModels = ["Gemini 3.8 Flash", "Gemini 3.7 Flash", "Gemini 3.6 Flash", "Gemini 3.1 Pro", "Claude Opus 5.5", "Claude Sonnet 5.5"]

    /// codex·grok 의 목록은 그 도구들이 디스크에 둔 것을 읽는다(없으면 빈 목록).
    static func load() -> AgentCatalog {
        AgentCatalog(codexModels: (try? CodexModels.load().listed.map(\.slug)) ?? [],
                     grokModels: GrokModels.load().models.map(\.id))
    }

    func models(for agent: Agent) -> [String] {
        switch agent {
        case .claude: return AgentCatalog.claudeModels
        case .codex: return codexModels
        case .grok: return grokModels
        case .cursor: return AgentCatalog.cursorModels
        case .antigravity: return AgentCatalog.antigravityModels
        case .opencode: return []
        }
    }

    static func efforts(for agent: Agent) -> [String] {
        switch agent {
        case .claude, .cursor: return ["low", "medium", "high", "xhigh", "max"]
        case .codex: return ["low", "medium", "high", "xhigh", "max", "ultra"]
        case .grok: return ["low", "medium", "high", "xhigh"]
        case .antigravity: return ["low", "medium", "high"]
        case .opencode: return ["Default", "low", "medium", "high", "max"]
        }
    }

    /// 프리셋에 에이전트를 새로 넣을 때의 첫 값.
    func starter(for agent: Agent) -> AgentPreset {
        AgentPreset(model: agent == .claude ? "opus" : models(for: agent).first ?? "", effort: "high")
    }
}

/// 편집 화면용 프리셋 한 개.
struct EditableSlot: Identifiable {
    let id = UUID()
    var name: String
    var presets: [Agent: AgentPreset]
    /// 편집 화면이 모르는 키 — 저장할 때 그대로 돌려준다.
    private let extra: [String: JSONValue]

    init(_ slot: Slot) {
        name = slot.name
        presets = slot.presets
        extra = slot.extra
    }

    /// 저장할 모양: 이름과 모델의 앞뒤 빈칸을 뗀다.
    var slot: Slot {
        var made = Slot(name: name.trimmingCharacters(in: .whitespaces))
        made.extra = extra
        for (agent, preset) in presets {
            var trimmed = preset
            trimmed.model = preset.model.trimmingCharacters(in: .whitespaces)
            made.presets[agent] = trimmed
        }
        return made
    }
}

final class SettingsModel: ObservableObject {
    @Published var slots: [EditableSlot] = []
    /// 펼쳐 놓은 프리셋들.
    @Published var expanded: Set<UUID> = []
    @Published var keepDefaults = true
    @Published var acceptSwitchPrompt = true
    @Published var effortKeys = true
    @Published var modifiers: Set<String> = Set(SlashCommandConfig.defaultModifiers)
    @Published var message = ""
    @Published var messageIsError = false
    /// 프리셋 파일을 읽지 못했을 때의 사유. 이때는 저장을 막는다 — 빈 화면을 저장하면 그 파일을 덮어쓴다.
    @Published var loadError: String?
    @Published var launchAtLogin = false

    let store: ConfigStore
    let onSaved: () -> Void
    let catalog: AgentCatalog
    /// 디스크에 있는 내용. 화면의 내용과 다르면 «저장하지 않은 변경» 이다.
    private var saved: SlashCommandConfig?

    init(store: ConfigStore, catalog: AgentCatalog = .load(), onSaved: @escaping () -> Void) {
        self.store = store
        self.catalog = catalog
        self.onSaved = onSaved
        reload()
    }

    var symbols: String {
        SlashCommandConfig(modifiers: SlashCommandConfig.knownModifiers.filter(modifiers.contains), slots: []).modifierSymbols
    }

    /// 화면의 내용으로 만든 설정. 편집 화면이 모르는 값(`version` 과 이 판이 모르는 키)은 읽은 것을 그대로 둔다.
    var draft: SlashCommandConfig {
        var made = SlashCommandConfig(version: saved?.version ?? 1,
                                      keepDefaults: keepDefaults,
                                      acceptSwitchPrompt: acceptSwitchPrompt,
                                      effortKeys: effortKeys,
                                      modifiers: SlashCommandConfig.knownModifiers.filter(modifiers.contains),
                                      slots: slots.map(\.slot))
        made.extra = saved?.extra ?? [:]
        return made
    }

    var isDirty: Bool {
        guard let saved else { return false }
        return draft != saved
    }

    var canSave: Bool { loadError == nil && isDirty }

    func reload() {
        do {
            let config = try store.load()
            saved = config
            slots = config.slots.map(EditableSlot.init)
            keepDefaults = config.keepDefaults
            acceptSwitchPrompt = config.acceptSwitchPrompt
            effortKeys = config.effortKeys
            modifiers = Set(config.modifiers)
            expanded = slots.count == 1 ? Set(slots.map(\.id)) : []
            loadError = nil
            say("")
        } catch {
            saved = nil
            loadError = "\(error)"
        }
        refreshLaunchAtLogin()
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    func add() {
        guard slots.count < SlashCommandConfig.maxSlots else { return }
        let slot = EditableSlot(Slot(claude: catalog.starter(for: .claude)))
        slots.append(slot)
        expanded.insert(slot.id)
    }

    func delete(_ id: UUID) {
        slots.removeAll { $0.id == id }
        expanded.remove(id)
    }

    /// 그 프리셋을 가리키는 바인딩. 지운 뒤에 늦게 온 갱신은 버린다(자리 번호로 묶으면 지울 때 범위를 벗어난다).
    func binding(for id: UUID, fallback: EditableSlot) -> Binding<EditableSlot> {
        Binding(get: { [weak self] in self?.slots.first { $0.id == id } ?? fallback },
                set: { [weak self] value in
                    guard let self, let index = self.slots.firstIndex(where: { $0.id == id }) else { return }
                    self.slots[index] = value
                })
    }

    func save() {
        guard loadError == nil else { return }
        for (index, slot) in slots.enumerated() {
            for agent in Agent.allCases {
                if let preset = slot.presets[agent], preset.model.trimmingCharacters(in: .whitespaces).isEmpty {
                    expanded.insert(slot.id)
                    say(loc("Preset %@: enter a model for %@.", index + 1, agent.displayName), error: true)
                    return
                }
            }
        }
        guard SlashCommandConfig.modifiersAreUsable(Array(modifiers)) else {
            say(loc("Pick Control, Option or Command for the shortcut. Shift alone would take over typing in the terminal."), error: true)
            return
        }
        do {
            let config = draft
            try store.save(config)
            saved = config
            say(loc("Saved"))
            onSaved()
        } catch {
            say(loc("Could not save: %@", error.localizedDescription), error: true)
        }
    }

    // MARK: 로그인할 때 실행

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
        } catch {
            say(loc("Could not change the login item: %@", error.localizedDescription), error: true)
        }
        refreshLaunchAtLogin()
    }
}

/// 로그인할 때 실행. 메뉴·편집 화면·명령줄이 같은 규칙을 쓴다.
enum LoginItem {
    /// «승인 대기» 도 등록된 상태다 — 다시 등록해도 달라지지 않으므로 그때는 시스템 설정의 로그인 항목 화면을 연다.
    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else if service.status != .enabled {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                PermissionsSection(model: permissions)
                presets
                shortcut
                behavior
                general
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 620)
        .frame(minHeight: 420, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var presets: some View {
        Section {
            if let problem = model.loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(loc("The presets file could not be read."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(problem).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(loc("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }
                        Button(loc("Read Again")) { model.reload() }
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                    PresetRow(shortcut: "\(model.symbols)\(index + 1)",
                              slot: model.binding(for: slot.id, fallback: slot),
                              isExpanded: Binding(get: { model.expanded.contains(slot.id) },
                                                  set: { open in if open { model.expanded.insert(slot.id) } else { model.expanded.remove(slot.id) } }),
                              catalog: model.catalog,
                              onDelete: { model.delete(slot.id) })
                }
                Button { model.add() } label: { Label(loc("Add Preset"), systemImage: "plus") }
                    .disabled(model.slots.count >= SlashCommandConfig.maxSlots)
            }
        } header: {
            Text(loc("Presets"))
        } footer: {
            Text(loc("In a supported terminal, press %@ and a number. The preset goes to whichever agent is running in the frontmost session; a preset does nothing for agents it has no entry for.", model.symbols))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcut: some View {
        Section {
            LabeledContent(loc("Modifier keys")) {
                HStack(spacing: 6) {
                    ForEach([("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")], id: \.0) { key, symbol in
                        Toggle(symbol, isOn: Binding(
                            get: { model.modifiers.contains(key) },
                            set: { on in if on { model.modifiers.insert(key) } else { model.modifiers.remove(key) } }))
                            .toggleStyle(.button)
                            .help(key.capitalized)
                    }
                    Text(loc("+ number")).foregroundStyle(.secondary)
                }
            }
            Toggle(loc("%@= and %@- raise and lower the effort only", model.symbols, model.symbols), isOn: $model.effortKeys)
        } header: {
            Text(loc("Shortcut"))
        } footer: {
            Text(loc("The shortcuts are taken only while a supported terminal is in front. Other apps keep these keys."))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var behavior: some View {
        Section {
            Toggle(isOn: $model.keepDefaults) {
                described(loc("Change this session only"),
                          loc("The default for new sessions stays as it is. Agents that always save the choice as their default get that default put back after the switch."))
            }
            Toggle(isOn: $model.acceptSwitchPrompt) {
                described(loc("Accept Claude Code's confirmation automatically"),
                          loc("Right after a reply, Claude Code asks again before changing the model or effort (it re-reads the conversation). Slash Command presses Enter only when that prompt asks about the value you chose."))
            }
        } header: {
            Text(loc("Behavior"))
        }
    }

    /// 스위치의 이름과 그 아래의 설명.
    private func described(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var general: some View {
        Section {
            Toggle(loc("Open at login"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            LabeledContent(loc("Presets file")) {
                HStack(spacing: 8) {
                    Text((model.store.url.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button(loc("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([model.store.url]) }
                }
            }
        } header: {
            Text(loc("General"))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !model.message.isEmpty, model.messageIsError || !model.isDirty {
                Label(model.message, systemImage: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.messageIsError ? Color.orange : Color.secondary)
                    .lineLimit(2)
            } else if model.isDirty {
                Text(loc("Unsaved changes")).foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc("Revert")) { model.reload() }.disabled(!model.isDirty)
            Button(loc("Save")) { model.save() }.keyboardShortcut(.defaultAction).disabled(!model.canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// 단축키를 키 모양으로 보여 준다(`⌥⇧1`).
private struct KeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
    }
}

/// 프리셋 한 개. 접혀 있으면 한 줄(단축키 · 이름 또는 요약), 펼치면 에이전트별 모델과 effort.
private struct PresetRow: View {
    let shortcut: String
    @Binding var slot: EditableSlot
    @Binding var isExpanded: Bool
    let catalog: AgentCatalog
    let onDelete: () -> Void

    private var agents: [Agent] { Agent.allCases.filter { slot.presets[$0] != nil } }
    private var missing: [Agent] { Agent.allCases.filter { slot.presets[$0] == nil } }

    /// 접힌 줄의 요약: `Claude Code opus · Codex gpt-6-astra · …`
    private var summary: String {
        let parts = agents.compactMap { agent in slot.presets[agent].map { "\(agent.displayName) \($0.model)" } }
        return parts.isEmpty ? loc("No agents set") : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("", text: $slot.name, prompt: Text(loc("Name (optional)")))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                ForEach(agents, id: \.self) { agent in
                    AgentRow(agent: agent,
                             preset: Binding(get: { slot.presets[agent] ?? catalog.starter(for: agent) },
                                             set: { if slot.presets[agent] != nil { slot.presets[agent] = $0 } }),
                             models: catalog.models(for: agent),
                             efforts: AgentCatalog.efforts(for: agent),
                             onRemove: { slot.presets[agent] = nil })
                }
                HStack {
                    Menu {
                        ForEach(missing, id: \.self) { agent in
                            Button(agent.displayName) { slot.presets[agent] = catalog.starter(for: agent) }
                        }
                    } label: {
                        Label(loc("Add Agent"), systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(missing.isEmpty)
                    Spacer()
                    Button(role: .destructive, action: onDelete) { Label(loc("Delete Preset"), systemImage: "trash") }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 10) {
                KeyBadge(text: shortcut)
                if !slot.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(slot.name).fontWeight(.medium).lineLimit(1)
                }
                Text(summary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    @Binding var preset: AgentPreset
    let models: [String]
    let efforts: [String]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.displayName).frame(width: 96, alignment: .leading)
            TextField("", text: $preset.model, prompt: Text(loc("Model")))
                .textFieldStyle(.roundedBorder).labelsHidden()
            Menu {
                ForEach(models, id: \.self) { name in Button(name) { preset.model = name } }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(models.isEmpty)
            .help(models.isEmpty ? loc("No model list for this agent. Type the name it shows on screen.") : loc("Choose a model"))
            Picker(loc("Effort"), selection: $preset.effort) {
                ForEach(efforts.contains(preset.effort) ? efforts : efforts + [preset.effort], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 104)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(loc("Remove %@ from this preset", agent.displayName))
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
            window.title = loc("Slash Command Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            // 너비는 고정하고 높이만 바꿀 수 있게 한다. 처음 높이는 화면에 맞춘다.
            let height = min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
            window.setContentSize(NSSize(width: 620, height: height))
            window.contentMinSize = NSSize(width: 620, height: 420)
            window.contentMaxSize = NSSize(width: 620, height: 10_000)
            window.center()
            self.window = window
        }
        // 저장하지 않은 편집이 있으면 그대로 둔다 — 창을 다시 불러냈다고 지우지 않는다.
        if model.isDirty { model.refreshLaunchAtLogin() } else { model.reload() }
        permissions.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
