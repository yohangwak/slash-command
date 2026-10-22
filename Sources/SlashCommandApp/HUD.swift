import AppKit

/// A notice that appears briefly at the bottom center of the screen. It does not take focus.
final class HUD {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    /// Incremented on every `show`. If a new notice appears while the previous one is fading out, this keeps the previous one's cleanup from removing the new one.
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

    /// If `seconds` is nil, it stays up until the next `show`.
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
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: [titleText, detailText].filter { !$0.isEmpty }.joined(separator: "\n"),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])

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
