import Carbon.HIToolbox
import Foundation

/// 조합 키 + 1 … 9 전역 단축키. Carbon 핫키는 키 위치로 잡으므로 한글 입력 상태와 무관하고 손쉬운 사용 권한도 필요 없다.
final class HotKeyCenter {
    var onPress: ((Int) -> Void)?
    /// 다른 앱이 이미 잡고 있어 등록하지 못한 번호.
    private(set) var failed: [Int] = []

    private var refs: [EventHotKeyRef] = []
    private(set) var registeredCount = 0
    private(set) var registeredModifiers: [String] = []
    private var handler: EventHandlerRef?

    private static let signature: OSType = 0x4D53_5754 // 'MSWT'
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

    func register(count: Int, modifiers: [String]) {
        let wanted = min(count, HotKeyCenter.keyCodes.count)
        guard wanted != registeredCount || modifiers != registeredModifiers else { return }
        unregister()
        let masks = ["shift": shiftKey, "option": optionKey, "control": controlKey, "command": cmdKey]
        let mask = modifiers.compactMap { masks[$0] }.reduce(0, |)
        for index in 0..<wanted {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: HotKeyCenter.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(HotKeyCenter.keyCodes[index]), UInt32(mask), id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                failed.append(index + 1)
            }
        }
        registeredCount = wanted
        registeredModifiers = modifiers
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        failed = []
        registeredCount = 0
        registeredModifiers = []
    }
}
