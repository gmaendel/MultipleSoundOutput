import CoreAudio
import Foundation

/// Thin, typed wrappers around the CoreAudio HAL property API.
enum CoreAudio {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: Introspection

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    // MARK: Getters

    static func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        scalar(object, address, initial: UInt32(0))
    }

    static func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        scalar(object, address, initial: Float32(0))
    }

    static func float64(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float64? {
        scalar(object, address, initial: Float64(0))
    }

    private static func scalar<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func dictionary(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [String: Any]? {
        var address = address
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [String: Any]
    }

    static func array(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [Any]? {
        var address = address
        var value: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? [Any]
    }

    static func objectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Total number of channels across a device's streams in the given scope.
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: Setters

    @discardableResult
    static func set(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, uint32 value: UInt32) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    @discardableResult
    static func set(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, float32 value: Float32) -> Bool {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    // MARK: Listeners

    /// Registers a property listener and returns a token that removes it when `remove()` is called.
    static func listen(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue = .main,
        _ handler: @escaping () -> Void
    ) -> ListenerToken? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return ListenerToken(object: object, address: address, queue: queue, block: block)
    }

    final class ListenerToken {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var removed = false

        fileprivate init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object
            self.address = address
            self.queue = queue
            self.block = block
        }

        func remove() {
            guard !removed else { return }
            removed = true
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }

        deinit { remove() }
    }
}

extension UInt32 {
    /// Renders a CoreAudio four-character code (e.g. transport types) for debugging.
    var fourCharCode: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(self)
    }
}
