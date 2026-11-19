import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audio = AudioController()
    private let hud = VolumeHUD()
    private var keys: MediaKeyMonitor!
    private var statusBar: StatusBarController!
    private var autoSwitchWork: DispatchWorkItem?
    private var pendingSwitchToDisplays = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        let firstLaunch = Settings.consumeFirstLaunch()

        keys = MediaKeyMonitor { [weak self] key, isRepeat, modifiers in
            self?.handle(key, isRepeat: isRepeat, modifiers: modifiers) ?? false
        }
        statusBar = StatusBarController(audio: audio, keys: keys)
        statusBar.onVolumeKeysToggled = { [weak self] enabled in
            if enabled { self?.keys.start(promptForPermission: true) } else { self?.keys.stop() }
        }

        audio.onChange = { [weak self] in self?.statusBar.refresh() }
        audio.onDisplaysConnected = { [weak self] in self?.switchOutputAutomatically(after: 1.0) }
        audio.onDisplaysDisconnected = { [weak self] in
            self?.switchOutputAutomatically(after: 1.0, toDisplays: false)
        }
        // Deleting the Multi-Output Device in use (e.g. in Audio MIDI Setup) leaves sound on one
        // display; put it back on all of them, making a new device if needed.
        audio.onDisplayOutputRemoved = { [weak self] in self?.switchOutputAutomatically(after: 1.0) }
        audio.startObserving()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.switchOutputAutomatically(after: 3.0)
        }

        if Settings.volumeKeysEnabled {
            // Only pop the system permission dialog on first launch; afterwards the menu offers it.
            keys.start(promptForPermission: firstLaunch)
        }

        switchOutputAutomatically(after: 0)
    }

    // MARK: Volume keys

    private func handle(_ key: MediaKey, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Only take over when macOS can't change the volume itself (multi-output devices).
        guard Settings.volumeKeysEnabled, audio.defaultOutputNeedsSoftwareVolume else { return false }

        let modifiers = modifiers.intersection([.shift, .option, .control, .command])
        // ⌥ + volume key opens Sound settings; leave that to macOS.
        if modifiers == .option { return false }
        let fine = modifiers.contains([.shift, .option])

        switch key {
        case .volumeUp:
            audio.stepVolume(up: true, fine: fine)
        case .volumeDown:
            audio.stepVolume(up: false, fine: fine)
        case .mute:
            if isRepeat { return true }
            audio.toggleMute()
        }

        statusBar.refresh()
        if Settings.showHUD {
            hud.show(volume: audio.volume, muted: audio.isMuted, title: statusBar.outputTitle)
        }
        return true
    }

    // MARK: Automatic switching

    /// Keeps sound where it belongs as displays come and go:
    /// - With `toDisplays`, moves it to the all-displays multi-output when two or more displays
    ///   are connected. This runs on launch, on wake, when a display is plugged in, and when the
    ///   multi-output in use is deleted — not when the user picks another output by hand.
    /// - Moves it to the Mac's own speakers when the displays it was playing through are all
    ///   unplugged. Any other output the user picked is left alone.
    private func switchOutputAutomatically(after delay: TimeInterval, toDisplays: Bool = true) {
        guard Settings.autoUseDisplays else { return }
        autoSwitchWork?.cancel()
        // A disconnect mustn't cancel a switch to the displays that is still pending (e.g. on wake).
        pendingSwitchToDisplays = pendingSwitchToDisplays || toDisplays
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let toDisplays = self.pendingSwitchToDisplays
            self.pendingSwitchToDisplays = false

            self.audio.reload()
            if toDisplays, self.audio.displaySpeakers.count >= 2, !self.audio.isUsingDisplayMultiOutput {
                do {
                    try self.audio.useAllDisplays()
                } catch {
                    NSLog("MultipleSoundOutput: automatic switch failed: \(error.localizedDescription)")
                }
            }
            self.audio.leaveUnpluggedDisplays()
            self.statusBar.refresh()
        }
        autoSwitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
