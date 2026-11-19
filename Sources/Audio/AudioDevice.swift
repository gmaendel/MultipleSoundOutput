import CoreAudio
import Foundation

/// A snapshot of one CoreAudio device that has output channels.
struct AudioDevice: Hashable, Identifiable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let modelUID: String
    let transportType: UInt32
    let outputChannels: Int

    init?(id: AudioObjectID) {
        let outputChannels = CoreAudio.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        guard outputChannels > 0,
              let uid = CoreAudio.string(id, CoreAudio.address(kAudioDevicePropertyDeviceUID))
        else { return nil }

        self.id = id
        self.uid = uid
        self.name = CoreAudio.string(id, CoreAudio.address(kAudioObjectPropertyName)) ?? "Unknown Device"
        self.modelUID = CoreAudio.string(id, CoreAudio.address(kAudioDevicePropertyModelUID)) ?? ""
        self.transportType = CoreAudio.uint32(id, CoreAudio.address(kAudioDevicePropertyTransportType)) ?? 0
        self.outputChannels = outputChannels
    }

    static func allOutputDevices() -> [AudioDevice] {
        CoreAudio.objectIDs(CoreAudio.systemObject, CoreAudio.address(kAudioHardwarePropertyDevices))
            .compactMap(AudioDevice.init(id:))
    }

    // MARK: Classification

    var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }

    /// Speakers built into an external display (Apple Studio Display, LG UltraFine, HDMI/DisplayPort monitors).
    var isDisplaySpeaker: Bool {
        if isAggregate { return false }
        if modelUID.hasPrefix("Studio Display") { return true }
        if transportType == kAudioDeviceTransportTypeHDMI || transportType == kAudioDeviceTransportTypeDisplayPort {
            return true
        }
        return name.localizedCaseInsensitiveContains("display")
            && transportType == kAudioDeviceTransportTypeUSB
    }

    /// The aggregate's composition dictionary (nil for normal devices).
    var aggregateComposition: [String: Any]? {
        guard isAggregate else { return nil }
        return CoreAudio.dictionary(id, CoreAudio.address(kAudioAggregateDevicePropertyComposition))
    }

    /// True for "Multi-Output" style aggregates, where every sub-device plays the same channels.
    var isStackedAggregate: Bool {
        guard let composition = aggregateComposition else { return false }
        return (composition[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.boolValue ?? false
    }

    /// UIDs of every sub-device the aggregate was configured with, connected or not.
    var aggregateSubDeviceUIDs: [String] {
        guard isAggregate else { return [] }
        let list = CoreAudio.array(id, CoreAudio.address(kAudioAggregateDevicePropertyFullSubDeviceList))
        return (list as? [String]) ?? []
    }

    /// Sub-devices that are currently connected and have outputs.
    var activeOutputSubDevices: [AudioObjectID] {
        guard isAggregate else { return [] }
        return CoreAudio.objectIDs(id, CoreAudio.address(kAudioAggregateDevicePropertyActiveSubDeviceList))
            .filter { CoreAudio.channelCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
    }
}

/// Volume and mute control for a single (non-aggregate) device.
///
/// Devices expose volume either on the main element (0) or per channel (1...n);
/// this handles both.
enum DeviceVolume {
    private static let scope = kAudioObjectPropertyScopeOutput

    /// Elements that carry a settable control for `selector` (main element preferred).
    static func elements(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [UInt32] {
        if CoreAudio.isSettable(device, CoreAudio.address(selector, scope, kAudioObjectPropertyElementMain)) {
            return [kAudioObjectPropertyElementMain]
        }
        let channels = CoreAudio.channelCount(device, scope: scope)
        guard channels > 0 else { return [] }
        return (1...UInt32(channels)).filter {
            CoreAudio.isSettable(device, CoreAudio.address(selector, scope, $0))
        }
    }

    static func hasVolumeControl(_ device: AudioObjectID) -> Bool {
        !elements(device, kAudioDevicePropertyVolumeScalar).isEmpty
    }

    static func volume(_ device: AudioObjectID) -> Float? {
        elements(device, kAudioDevicePropertyVolumeScalar)
            .compactMap { CoreAudio.float32(device, CoreAudio.address(kAudioDevicePropertyVolumeScalar, scope, $0)) }
            .max()
    }

    static func setVolume(_ device: AudioObjectID, _ value: Float) {
        let clamped = min(max(value, 0), 1)
        for element in elements(device, kAudioDevicePropertyVolumeScalar) {
            CoreAudio.set(device, CoreAudio.address(kAudioDevicePropertyVolumeScalar, scope, element), float32: clamped)
        }
    }

    static func isMuted(_ device: AudioObjectID) -> Bool? {
        let values = elements(device, kAudioDevicePropertyMute)
            .compactMap { CoreAudio.uint32(device, CoreAudio.address(kAudioDevicePropertyMute, scope, $0)) }
        guard !values.isEmpty else { return nil }
        return values.allSatisfy { $0 != 0 }
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        for element in elements(device, kAudioDevicePropertyMute) {
            CoreAudio.set(device, CoreAudio.address(kAudioDevicePropertyMute, scope, element), uint32: muted ? 1 : 0)
        }
    }

    /// Addresses worth observing to keep UI in sync with external volume changes.
    static func observableAddresses(_ device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        elements(device, kAudioDevicePropertyVolumeScalar).map {
            CoreAudio.address(kAudioDevicePropertyVolumeScalar, scope, $0)
        } + elements(device, kAudioDevicePropertyMute).map {
            CoreAudio.address(kAudioDevicePropertyMute, scope, $0)
        }
    }
}
