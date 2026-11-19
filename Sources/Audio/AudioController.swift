import CoreAudio
import Foundation

enum AudioControllerError: LocalizedError {
    case notEnoughDisplays(found: Int)
    case createFailed(OSStatus)
    case selectFailed(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughDisplays(let found):
            return "Two or more display speakers are needed, but \(found) \(found == 1 ? "is" : "are") connected."
        case .createFailed(let status):
            return "macOS refused to create the multi-output device (error \(status))."
        case .selectFailed(let name):
            return "Could not switch the sound output to “\(name)”."
        }
    }
}

/// Owns the view of the audio system: output devices, the default output, and volume/mute
/// for the default output — including Multi-Output (aggregate) devices, whose volume is
/// applied to every sub-device because macOS gives aggregates no volume control of their own.
final class AudioController {
    /// Called on the main queue whenever devices, the default output, volume or mute change.
    var onChange: (() -> Void)?
    /// Called on the main queue when the set of connected display speakers grows.
    var onDisplaysConnected: (() -> Void)?
    /// Called on the main queue when a display speaker is unplugged.
    var onDisplaysDisconnected: (() -> Void)?

    static let volumeStep: Float = 1.0 / 16.0
    static let fineVolumeStep: Float = 1.0 / 64.0

    /// UID used when this app has to create its own multi-output device.
    static let managedAggregateUID = "MultipleSoundOutput.AllDisplays"
    static let managedAggregateName = "All Displays"

    private(set) var devices: [AudioDevice] = []
    private(set) var defaultOutputID: AudioObjectID = 0

    private var systemListeners: [CoreAudio.ListenerToken] = []
    private var volumeListeners: [CoreAudio.ListenerToken] = []
    private var notifyScheduled = false
    private var connectedDisplayUIDs: Set<String> = []

    init() {
        reload()
        connectedDisplayUIDs = Set(displaySpeakers.map(\.uid))
    }

    /// Start observing CoreAudio (only needed by the menu bar app, not the CLI).
    func startObserving() {
        let system = CoreAudio.systemObject
        systemListeners = [
            CoreAudio.address(kAudioHardwarePropertyDevices),
            CoreAudio.address(kAudioHardwarePropertyDefaultOutputDevice),
        ].compactMap { address in
            CoreAudio.listen(system, address) { [weak self] in self?.systemChanged() }
        }
        observeVolume()
    }

    // MARK: Devices

    func reload() {
        devices = AudioDevice.allOutputDevices()
        defaultOutputID = CoreAudio.uint32(
            CoreAudio.systemObject, CoreAudio.address(kAudioHardwarePropertyDefaultOutputDevice)
        ) ?? 0
        rememberDisplays()
    }

    private func rememberDisplays() {
        let connected = Set(displaySpeakers.map(\.uid))
        let remembered = Settings.rememberedDisplayUIDs
        if !connected.isSubset(of: remembered) {
            Settings.rememberedDisplayUIDs = remembered.union(connected)
        }
    }

    var defaultOutput: AudioDevice? { devices.first { $0.id == defaultOutputID } }

    var displaySpeakers: [AudioDevice] {
        devices.filter(\.isDisplaySpeaker).sorted { $0.uid < $1.uid }
    }

    /// Human-friendly name, numbering devices that share a name (e.g. two "Studio Display Speakers").
    func displayName(for device: AudioDevice) -> String {
        let twins = devices.filter { $0.name == device.name }.sorted { $0.uid < $1.uid }
        guard twins.count > 1, let index = twins.firstIndex(of: device) else { return device.name }
        return "\(device.name) \(index + 1)"
    }

    @discardableResult
    func select(_ device: AudioDevice) -> Bool {
        let ok = CoreAudio.set(
            CoreAudio.systemObject,
            CoreAudio.address(kAudioHardwarePropertyDefaultOutputDevice),
            uint32: device.id
        )
        reload()
        observeVolume()
        scheduleNotify()
        return ok
    }

    // MARK: Volume of the default output

    /// The physical devices whose volume we drive for `device`.
    func volumeTargets(for device: AudioDevice?) -> [AudioObjectID] {
        guard let device else { return [] }
        if DeviceVolume.hasVolumeControl(device.id) { return [device.id] }
        if device.isAggregate {
            return device.activeOutputSubDevices.filter(DeviceVolume.hasVolumeControl)
        }
        return []
    }

    /// True when macOS can't change the default output's volume itself, so we must do it in software.
    var defaultOutputNeedsSoftwareVolume: Bool {
        guard let device = defaultOutput else { return false }
        return !DeviceVolume.hasVolumeControl(device.id) && !volumeTargets(for: device).isEmpty
    }

    var canControlVolume: Bool { !volumeTargets(for: defaultOutput).isEmpty }

    var volume: Float {
        volumeTargets(for: defaultOutput).compactMap(DeviceVolume.volume).max() ?? 0
    }

    var isMuted: Bool {
        let targets = volumeTargets(for: defaultOutput)
        guard !targets.isEmpty else { return false }
        return targets.allSatisfy { DeviceVolume.isMuted($0) ?? false }
    }

    func setVolume(_ value: Float) {
        let value = min(max(value, 0), 1)
        for target in volumeTargets(for: defaultOutput) {
            DeviceVolume.setVolume(target, value)
            DeviceVolume.setMuted(target, value < 0.001)
        }
        scheduleNotify()
    }

    /// Steps the volume like the keyboard keys do, snapping to the step grid.
    func stepVolume(up: Bool, fine: Bool = false) {
        let step = fine ? Self.fineVolumeStep : Self.volumeStep
        let snapped = (volume / step).rounded() * step
        setVolume(snapped + (up ? step : -step))
    }

    func setMuted(_ muted: Bool) {
        let targets = volumeTargets(for: defaultOutput)
        for target in targets {
            DeviceVolume.setMuted(target, muted)
        }
        // Unmuting at zero volume would be silent; bring it back to one step.
        if !muted, volume < 0.001 {
            for target in targets { DeviceVolume.setVolume(target, Self.volumeStep) }
        }
        scheduleNotify()
    }

    func toggleMute() { setMuted(!isMuted) }

    // MARK: Multi-output for all displays

    /// An existing stacked (Multi-Output) aggregate made of exactly the connected display speakers.
    func displayMultiOutput() -> AudioDevice? {
        let wanted = Set(displaySpeakers.map(\.uid))
        guard wanted.count >= 2 else { return nil }
        let candidates = devices.filter { device in
            device.isStackedAggregate && Set(device.aggregateSubDeviceUIDs) == wanted
        }
        // Prefer one the user made in Audio MIDI Setup over ours.
        return candidates.first { $0.uid != Self.managedAggregateUID } ?? candidates.first
    }

    var isUsingDisplayMultiOutput: Bool {
        guard let multi = displayMultiOutput() else { return false }
        return multi.id == defaultOutputID
    }

    /// Makes every connected display speaker play together, creating a Multi-Output device if needed.
    @discardableResult
    func useAllDisplays() throws -> AudioDevice {
        reload()
        let displays = displaySpeakers
        guard displays.count >= 2 else { throw AudioControllerError.notEnoughDisplays(found: displays.count) }

        let device = try displayMultiOutput() ?? createMultiOutput(for: displays)
        if device.id != defaultOutputID, !select(device) {
            throw AudioControllerError.selectFailed(device.name)
        }
        return device
    }

    func createMultiOutput(for displays: [AudioDevice]) throws -> AudioDevice {
        // Replace a stale copy of our own device (e.g. a display was swapped).
        if let stale = devices.first(where: { $0.uid == Self.managedAggregateUID }) {
            AudioHardwareDestroyAggregateDevice(stale.id)
        }

        let subDevices: [[String: Any]] = displays.enumerated().map { index, display in
            [
                kAudioSubDeviceUIDKey: display.uid,
                // The first display is the clock master; resample the others to stay in sync.
                kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1,
            ]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.managedAggregateName,
            kAudioAggregateDeviceUIDKey: Self.managedAggregateUID,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: displays[0].uid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]

        var newID: AudioObjectID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr else { throw AudioControllerError.createFailed(status) }

        // The HAL finishes publishing the device asynchronously; give it a moment.
        for _ in 0..<20 {
            reload()
            if let device = devices.first(where: { $0.id == newID }), !device.activeOutputSubDevices.isEmpty {
                return device
            }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
        reload()
        guard let device = devices.first(where: { $0.id == newID }) else {
            throw AudioControllerError.createFailed(status)
        }
        return device
    }

    // MARK: Leaving unplugged displays

    /// True when `id` is a Multi-Output Device made only of display speakers, none of which
    /// is connected any more (e.g. after unplugging the Mac from its displays).
    func isUnpluggedDisplayMultiOutput(_ id: AudioObjectID) -> Bool {
        guard let subDevices = AudioDevice.multiOutputSubDeviceUIDs(of: id).map(Set.init),
              !subDevices.isEmpty
        else { return false }
        let connected = Set(displaySpeakers.map(\.uid))
        let displays = Settings.rememberedDisplayUIDs.union(connected)
        return subDevices.isSubset(of: displays) && subDevices.isDisjoint(with: connected)
    }

    /// Sound is going to a Multi-Output Device of displays that are all unplugged, so nothing plays.
    var isPlayingToUnpluggedDisplays: Bool { isUnpluggedDisplayMultiOutput(defaultOutputID) }

    /// The Mac's own output: the headphone jack when something is plugged into it, otherwise
    /// the built-in speakers.
    var builtInOutput: AudioDevice? {
        let builtIn = devices.filter { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
        return builtIn.first { $0.uid.localizedCaseInsensitiveContains("headphone") } ?? builtIn.first
    }

    /// If sound is going to displays that are all unplugged, moves it to the Mac's own output.
    /// Returns the new output, or nil when nothing needed to change.
    @discardableResult
    func leaveUnpluggedDisplays() -> AudioDevice? {
        reload()
        guard isPlayingToUnpluggedDisplays, let builtIn = builtInOutput, select(builtIn) else { return nil }
        return builtIn
    }

    // MARK: Change tracking

    private func systemChanged() {
        reload()
        observeVolume()

        let displayUIDs = Set(displaySpeakers.map(\.uid))
        let gained = !displayUIDs.subtracting(connectedDisplayUIDs).isEmpty
        let lost = !connectedDisplayUIDs.subtracting(displayUIDs).isEmpty
        connectedDisplayUIDs = displayUIDs
        if gained { onDisplaysConnected?() }
        if lost { onDisplaysDisconnected?() }

        scheduleNotify()
    }

    private func observeVolume() {
        volumeListeners.forEach { $0.remove() }
        volumeListeners = volumeTargets(for: defaultOutput).flatMap { target in
            DeviceVolume.observableAddresses(target).compactMap { address in
                CoreAudio.listen(target, address) { [weak self] in self?.scheduleNotify() }
            }
        }
    }

    /// Coalesces bursts of HAL notifications into one UI update.
    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.onChange?()
        }
    }
}
