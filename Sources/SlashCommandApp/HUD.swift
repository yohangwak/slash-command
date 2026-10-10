import AppKit

/// 화면 아래쪽 가운데에 잠깐 뜨는 알림. 포커스를 가져가지 않는다.
final class HUD {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    /// `show` 마다 하나씩 는다. 앞 알림이 사라지는 중에 새 알림이 뜨면, 앞 알림의 마무리가 새 알림을 치우지 않게 한다.
    private var shown = 0

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 5
        detail.preferredMaxLayoutWidth = 320

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: 360),
        ])
        panel.contentView = background
    }

    /// `seconds` 가 nil 이면 다음 `show` 까지 떠 있다.
    func show(_ titleText: String, detail detailText: String = "", seconds: TimeInterval? = 1.6) {
        hideWork?.cancel()
        shown += 1
        let current = shown
        title.stringValue = titleText
        detail.stringValue = detailText
        detail.isHidden = detailText.isEmpty

        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 80)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 120,
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self?.panel.animator().alphaValue = 0
            }, completionHandler: {
                guard let self, self.shown == current else { return }
                self.panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
