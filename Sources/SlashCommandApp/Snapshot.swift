import AppKit
import SlashCommandCore
import SwiftUI

/// 개발용: 설정 창의 내용을 화면에 띄우지 않고 그림 파일로 낸다.
/// 화면 녹화 권한 없이 배치와 번역(`SLASHCOMMAND_LANG=ja` 처럼)을 눈으로 확인하려는 것이다. 아무것도 저장하지 않는다.
enum SettingsSnapshot {
    static func write(to url: URL, height: Double, dark: Bool, expandFirst: Bool) -> Bool {
        let model = SettingsModel(store: ConfigStore(), onSaved: {})
        model.expanded = expandFirst ? Set(model.slots.prefix(1).map(\.id)) : []
        let permissions = PermissionsModel()
        permissions.refresh()
        // 오른쪽에서 왼쪽으로 쓰는 언어는 실제 앱에서 시스템이 방향을 뒤집는다. 여기서는 직접 맞춘다.
        let direction: LayoutDirection = Locale.Language(identifier: L10n.language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
        let view = SettingsView(model: model, permissions: permissions).environment(\.layoutDirection, direction)
        let hosting = NSHostingView(rootView: view)
        let frame = NSRect(x: -30_000, y: -30_000, width: 620, height: height)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        // 자동화 권한 확인과 SwiftUI 의 첫 배치가 끝나기를 잠깐 기다린다.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
