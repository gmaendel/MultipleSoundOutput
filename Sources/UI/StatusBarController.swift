import AppKit
import CoreAudio

/// The menu bar icon and its menu.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let audio: AudioController
    private let keys: MediaKeyMonitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
    private let menu = NSMenu()
    private let volumeView = VolumeMenuView()

    /// Called when the user changes whether the volume keys should be intercepted.
    var onVolumeKeysToggled: ((Bool) -> Void)?

    init(audio: AudioController, keys: MediaKeyMonitor) {
        self.audio = audio
        self.keys = keys
        super.init()

        statusItem.button?.imagePosition = .imageOnly
        statusItem.behavior = .removalAllowed
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        volumeView.onVolumeChange = { [weak self] value in
            self?.audio.setVolume(value)
            self?.refresh()
        }
        refresh()
    }

    /// Short description of where sound is going, for the HUD and tooltip.
    var outputTitle: String {
        if audio.isUsingDisplayMultiOutput {
            let count = audio.displaySpeakers.count
            return count == 2 ? "Both Displays" : "All \(count) Displays"
        }
        return audio.defaultOutput.map(audio.displayName(for:)) ?? "No Output"
    }

    func refresh() {
        let volume = audio.volume
        let muted = audio.isMuted
        let canControl = audio.canControlVolume

        let image = SpeakerSymbol.image(volume: canControl ? volume : 1, muted: canControl && muted, pointSize: 14)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !canControl

        let percent = "\(Int((volume * 100).rounded()))%"
        let level = canControl ? (muted ? "Muted" : percent) : "Fixed volume"
        statusItem.button?.toolTip = "\(outputTitle) — \(level)"
        volumeView.update(volume: volume, muted: muted, enabled: canControl, detail: level)
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        audio.reload()
        rebuildMenu()
        refresh()
    }

    // MARK: Menu

    private func rebuildMenu() {
        menu.removeAllItems()

        let volumeItem = NSMenuItem()
        volumeItem.view = volumeView
        menu.addItem(volumeItem)
        menu.addItem(.separator())

        // Output devices
        menu.addItem(sectionHeader("Output"))
        let displays = audio.displaySpeakers
        let displayMulti = audio.displayMultiOutput()

        if displays.count >= 2 {
            let title = displays.count == 2 ? "Both Displays" : "All \(displays.count) Displays"
            let item = NSMenuItem(title: title, action: #selector(useAllDisplays), keyEquivalent: "")
            item.target = self
            item.image = symbol("display.2")
            item.state = audio.isUsingDisplayMultiOutput ? .on : .off
            if #available(macOS 14.4, *) {
                item.subtitle = displays.map(audio.displayName(for:)).joined(separator: " + ")
            }
            menu.addItem(item)
        }

        for device in audio.devices where device.id != displayMulti?.id {
            let item = NSMenuItem(title: audio.displayName(for: device), action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.image = symbol(icon(for: device))
            item.state = device.id == audio.defaultOutputID ? .on : .off
            if #available(macOS 14.4, *), device.isAggregate {
                let names = device.activeOutputSubDevices.compactMap { id in
                    audio.devices.first { $0.id == id }.map(audio.displayName(for:))
                }
                item.subtitle = names.isEmpty ? "No devices connected" : names.joined(separator: " + ")
            }
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Options
        menu.addItem(sectionHeader("Options"))

        let keysItem: NSMenuItem
        if Settings.volumeKeysEnabled && !MediaKeyMonitor.hasPermission {
            keysItem = NSMenuItem(title: "Allow Keyboard Volume Keys…", action: #selector(requestKeyPermission), keyEquivalent: "")
            keysItem.image = symbol("exclamationmark.triangle")
            if #available(macOS 14.4, *) {
                keysItem.subtitle = "Needs Accessibility permission"
            }
        } else {
            keysItem = NSMenuItem(title: "Use Keyboard Volume Keys", action: #selector(toggleVolumeKeys), keyEquivalent: "")
            keysItem.state = Settings.volumeKeysEnabled ? .on : .off
        }
        keysItem.target = self
        menu.addItem(keysItem)

        menu.addItem(toggle("Show Volume on Screen", on: Settings.showHUD, action: #selector(toggleHUD)))
        let autoItem = toggle("Switch Output Automatically", on: Settings.autoUseDisplays, action: #selector(toggleAutoDisplays))
        if #available(macOS 14.4, *) {
            autoItem.subtitle = "Displays when connected, otherwise \(audio.builtInOutput?.name ?? "the Mac’s speakers")"
        }
        menu.addItem(autoItem)
        menu.addItem(toggle("Open at Login", on: LaunchAtLogin.isEnabled, action: #selector(toggleLaunchAtLogin)))

        menu.addItem(.separator())
        menu.addItem(action("Sound Settings…", #selector(openSoundSettings)))
        menu.addItem(action("Audio MIDI Setup…", #selector(openAudioMIDISetup)))
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MultipleSoundOutput", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func icon(for device: AudioDevice) -> String {
        if device.isAggregate { return "hifispeaker.2" }
        if device.isDisplaySpeaker { return "display" }
        switch device.transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        default: return "speaker.wave.2"
        }
    }

    // MARK: Actions

    @objc private func useAllDisplays() {
        do {
            try audio.useAllDisplays()
        } catch {
            showError("Couldn’t play on all displays", error)
        }
        refresh()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? AudioDevice else { return }
        if !audio.select(device) {
            showError("Couldn’t switch output", AudioControllerError.selectFailed(device.name))
        }
        refresh()
    }

    @objc private func toggleVolumeKeys() {
        Settings.volumeKeysEnabled.toggle()
        onVolumeKeysToggled?(Settings.volumeKeysEnabled)
    }

    @objc private func requestKeyPermission() {
        keys.start(promptForPermission: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleHUD() {
        Settings.showHUD.toggle()
    }

    @objc private func toggleAutoDisplays() {
        Settings.autoUseDisplays.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        } catch {
            showError("Couldn’t change Open at Login", error)
        }
    }

    @objc private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAudioMIDISetup() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
    }

    private func showError(_ title: String, _ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
