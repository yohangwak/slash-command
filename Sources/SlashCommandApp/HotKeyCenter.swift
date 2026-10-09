import Carbon.HIToolbox
import Foundation

/// 조합 키 + 1 … 9 전역 단축키, 그리고 조합 키 + `=` · `-`(effort 올림·내림). Carbon 핫키는 키 위치로 잡으므로 한글 입력 상태와 무관하고 손쉬운 사용 권한도 필요 없다.
final class HotKeyCenter {
    var onPress: ((Int) -> Void)?
    /// 다른 앱이 이미 잡고 있어 등록하지 못한 번호.
    private(set) var failed: [Int] = []

    private var refs: [EventHotKeyRef] = []
    private(set) var registeredCount = 0
    private(set) var registeredModifiers: [String] = []
    private(set) var registeredEffortKeys = false
    private var handler: EventHandlerRef?

    /// `onPress` 로 넘어오는 번호: 1 … 9 는 프리셋, 아래 둘은 effort 한 단계.
    static let effortUp = 101
    static let effortDown = 102

    private static let signature: OSType = 0x534C_434D // 'SLCM'
    private static let keyCodes = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            center.onPress?(Int(id.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(count: Int, modifiers: [String], effortKeys: Bool) {
        let wanted = min(count, HotKeyCenter.keyCodes.count)
        guard wanted != registeredCount || modifiers != registeredModifiers || effortKeys != registeredEffortKeys else { return }
        unregister()
        let masks = ["shift": shiftKey, "option": optionKey, "control": controlKey, "command": cmdKey]
        let mask = modifiers.compactMap { masks[$0] }.reduce(0, |)
        var keys = (0..<wanted).map { (id: $0 + 1, code: HotKeyCenter.keyCodes[$0]) }
        if effortKeys {
            keys.append((HotKeyCenter.effortUp, kVK_ANSI_Equal))
            keys.append((HotKeyCenter.effortDown, kVK_ANSI_Minus))
        }
        for key in keys {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotKeyCenter.signature, id: UInt32(key.id))
            let status = RegisterEventHotKey(UInt32(key.code), UInt32(mask), id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(key.id)
            }
        }
        registeredCount = wanted
        registeredModifiers = modifiers
        registeredEffortKeys = effortKeys
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        failed = []
        registeredCount = 0
        registeredModifiers = []
        registeredEffortKeys = false
    }
}
