import AppKit

/// A small on-screen volume indicator, shown when the volume keys are used.
///
/// macOS shows "volume can't be changed" for multi-output devices, so we draw our own,
/// in the top-right corner of the screen under the mouse pointer.
final class VolumeHUD {
    private let size = NSSize(width: 290, height: 64)
    private var panel: NSPanel?
    private var iconView: NSImageView!
    private var titleField: NSTextField!
    private var levelView: LevelBarView!
    private var hideWorkItem: DispatchWorkItem?
    private var generation = 0

    func show(volume: Float, muted: Bool, title: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        iconView.image = SpeakerSymbol.image(volume: volume, muted: muted, pointSize: 22, weight: .medium)
        titleField.stringValue = title
        levelView.level = muted ? 0 : CGFloat(volume)

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 10))
        }

        hideWorkItem?.cancel()
        generation += 1
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        let generationAtHide = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Don't hide if the HUD was shown again while fading out.
            guard let self, self.generation == generationAtHide else { return }
            panel.orderOut(nil)
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true

        iconView = NSImageView(frame: NSRect(x: 14, y: 14, width: 36, height: 36))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor

        titleField = NSTextField(labelWithString: "")
        titleField.frame = NSRect(x: 58, y: 34, width: size.width - 74, height: 16)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        levelView = LevelBarView(frame: NSRect(x: 58, y: 16, width: size.width - 74, height: 8))

        background.addSubview(iconView)
        background.addSubview(titleField)
        background.addSubview(levelView)
        panel.contentView = background
        return panel
    }
}

/// A rounded progress track, like the one in Control Center's sound slider.
final class LevelBarView: NSView {
    var level: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let clamped = min(max(level, 0), 1)
        guard clamped > 0 else { return }
        let width = max(bounds.height, bounds.width * clamped)
        NSColor.labelColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

enum SpeakerSymbol {
    /// Uses the variable-value speaker symbol (like Control Center) so the icon keeps a constant width.
    static func image(volume: Float, muted: Bool, pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image: NSImage?
        if muted || volume < 0.001 {
            image = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Muted")
        } else {
            image = NSImage(
                systemSymbolName: "speaker.wave.3.fill",
                variableValue: Double(volume),
                accessibilityDescription: "Volume \(Int((volume * 100).rounded())) percent"
            )
        }
        return image?.withSymbolConfiguration(config)
    }
}
