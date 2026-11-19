import AppKit
import ApplicationServices

enum MediaKey {
    case volumeUp, volumeDown, mute
}

/// Intercepts the keyboard volume keys with a Quartz event tap.
///
/// The tap needs Accessibility permission. The handler decides per key press whether to
/// consume the event (we only do so when the current output is a multi-output device that
/// macOS itself can't change the volume of); otherwise the event passes through untouched.
final class MediaKeyMonitor {
    /// Return true to consume the key press.
    typealias Handler = (_ key: MediaKey, _ isRepeat: Bool, _ modifiers: NSEvent.ModifierFlags) -> Bool

    private let handler: Handler
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var consumedKeyDowns: Set<Int32> = []

    var onStateChange: (() -> Void)?

    // From IOKit/hidsystem/ev_keymap.h
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!  // NX_SYSDEFINED
    private static let auxControlButtonsSubtype: Int16 = 8                   // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let keySoundUp: Int32 = 0                                 // NX_KEYTYPE_SOUND_UP
    private static let keySoundDown: Int32 = 1                               // NX_KEYTYPE_SOUND_DOWN
    private static let keyMute: Int32 = 7                                    // NX_KEYTYPE_MUTE

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit { stop() }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Starts the tap, asking for Accessibility permission if needed and waiting until it's granted.
    func start(promptForPermission: Bool) {
        if tap != nil { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptForPermission] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            waitForPermission()
            return
        }

        let mask = CGEventMask(1 << Self.systemDefinedEventType.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("MultipleSoundOutput: could not create the volume key event tap")
            waitForPermission()
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        permissionTimer?.invalidate()
        permissionTimer = nil
        onStateChange?()
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        consumedKeyDowns.removeAll()
        onStateChange?()
    }

    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, Self.hasPermission else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.start(promptForPermission: false)
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passThrough
        }

        guard type == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlButtonsSubtype
        else { return passThrough }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0xA
        let isRepeat = (keyFlags & 0x1) == 1

        let key: MediaKey
        switch keyCode {
        case Self.keySoundUp: key = .volumeUp
        case Self.keySoundDown: key = .volumeDown
        case Self.keyMute: key = .mute
        default: return passThrough
        }

        if !isKeyDown {
            // Swallow the key-up only if we swallowed its key-down.
            return consumedKeyDowns.remove(keyCode) != nil ? nil : passThrough
        }

        if handler(key, isRepeat, nsEvent.modifierFlags) {
            consumedKeyDowns.insert(keyCode)
            return nil
        }
        return passThrough
    }
}

private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
