import AppKit

/// The "Sound" header with a volume slider, embedded at the top of the status menu.
final class VolumeMenuView: NSView {
    var onVolumeChange: ((Float) -> Void)?

    private let titleField = NSTextField(labelWithString: "Sound")
    private let detailField = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let lowIcon = NSImageView()
    private let highIcon = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 66))

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.frame = NSRect(x: 14, y: 42, width: 120, height: 17)

        detailField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .right
        detailField.frame = NSRect(x: 140, y: 43, width: 136, height: 15)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        lowIcon.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        highIcon.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        for icon in [lowIcon, highIcon] {
            icon.contentTintColor = .secondaryLabelColor
            icon.imageScaling = .scaleNone
        }
        lowIcon.frame = NSRect(x: 12, y: 10, width: 18, height: 20)
        highIcon.frame = NSRect(x: 258, y: 10, width: 22, height: 20)

        slider.frame = NSRect(x: 34, y: 10, width: 220, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.setAccessibilityLabel("Volume")

        [titleField, detailField, lowIcon, highIcon, slider].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(volume: Float, muted: Bool, enabled: Bool, detail: String) {
        // Don't fight the user while they're dragging.
        if NSEvent.pressedMouseButtons == 0 || !enabled {
            slider.doubleValue = muted ? 0 : Double(volume)
        }
        slider.isEnabled = enabled
        detailField.stringValue = detail
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        onVolumeChange?(Float(sender.doubleValue))
    }
}
