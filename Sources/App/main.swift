import AppKit

// Command-line mode (e.g. `--status`, `--volume 40`); see CommandLineInterface.swift.
if let exitCode = CommandLineInterface.run(CommandLine.arguments) {
    exit(exitCode)
}

// Only one copy should hold the volume keys.
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
       .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
