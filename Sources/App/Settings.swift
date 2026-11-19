import Foundation
import ServiceManagement

/// User preferences, stored in UserDefaults.
enum Settings {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let autoUseDisplays = "AutoUseAllDisplays"
        static let volumeKeys = "ControlVolumeKeys"
        static let showHUD = "ShowVolumeHUD"
        static let hasLaunchedBefore = "HasLaunchedBefore"
        static let rememberedDisplays = "RememberedDisplayUIDs"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.autoUseDisplays: true,
            Key.volumeKeys: true,
            Key.showHUD: true,
        ])
    }

    /// Switch to the all-displays multi-output on launch, on wake, and when a display is plugged in,
    /// and back to the Mac's own speakers when those displays are unplugged.
    static var autoUseDisplays: Bool {
        get { defaults.bool(forKey: Key.autoUseDisplays) }
        set { defaults.set(newValue, forKey: Key.autoUseDisplays) }
    }

    static var volumeKeysEnabled: Bool {
        get { defaults.bool(forKey: Key.volumeKeys) }
        set { defaults.set(newValue, forKey: Key.volumeKeys) }
    }

    static var showHUD: Bool {
        get { defaults.bool(forKey: Key.showHUD) }
        set { defaults.set(newValue, forKey: Key.showHUD) }
    }

    /// UIDs of every display speaker seen on this Mac, so a Multi-Output Device made of displays
    /// can still be recognised after they're unplugged.
    static var rememberedDisplayUIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.rememberedDisplays) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Key.rememberedDisplays) }
    }

    /// True only the first time the app runs.
    static func consumeFirstLaunch() -> Bool {
        defer { defaults.set(true, forKey: Key.hasLaunchedBefore) }
        return !defaults.bool(forKey: Key.hasLaunchedBefore)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
