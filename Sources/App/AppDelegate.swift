import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audio = AudioController()
    private let hud = VolumeHUD()
    private var keys: MediaKeyMonitor!
    private var statusBar: StatusBarController!
    private var autoSwitchWork: DispatchWorkItem?

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
        audio.onDisplaysConnected = { [weak self] in self?.switchToDisplaysIfWanted(after: 1.0) }
        audio.startObserving()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.switchToDisplaysIfWanted(after: 3.0)
        }

        if Settings.volumeKeysEnabled {
            // Only pop the system permission dialog on first launch; afterwards the menu offers it.
            keys.start(promptForPermission: firstLaunch)
        }

        switchToDisplaysIfWanted(after: 0)
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

    /// Moves sound to the all-displays multi-output when two or more displays are connected.
    /// Runs on launch, on wake, and when a display is plugged in — not when the user picks
    /// another output by hand.
    private func switchToDisplaysIfWanted(after delay: TimeInterval) {
        guard Settings.autoUseDisplays else { return }
        autoSwitchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.audio.reload()
            guard self.audio.displaySpeakers.count >= 2, !self.audio.isUsingDisplayMultiOutput else { return }
            do {
                try self.audio.useAllDisplays()
                self.statusBar.refresh()
            } catch {
                NSLog("MultipleSoundOutput: automatic switch failed: \(error.localizedDescription)")
            }
        }
        autoSwitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
