import Foundation

/// Optional command-line control, e.g. for scripts or Shortcuts:
///
///     MultipleSoundOutput.app/Contents/MacOS/MultipleSoundOutput --status
enum CommandLineInterface {
    static let usage = """
    Usage: MultipleSoundOutput [command]

    With no command, runs the menu bar app.

    Commands:
      --list              List output devices
      --status            Show the current output, volume and mute state
      --volume <0-100>    Set the volume of the current output (all displays for a multi-output)
      --up / --down       Step the volume like the keyboard keys
      --mute / --unmute   Mute or unmute the current output
      --use-displays      Play on all connected display speakers (creates a multi-output if needed)
      --select <name|uid> Switch the sound output to a device
      --help              Show this help
    """

    /// Returns an exit code if the arguments were a CLI command, or nil to launch the app.
    static func run(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
        guard let command = args.first, command.hasPrefix("--") else { return nil }
        let audio = AudioController()

        switch command {
        case "--help", "-h":
            print(usage)
        case "--list":
            for device in audio.devices {
                var tags: [String] = []
                if device.id == audio.defaultOutputID { tags.append("current") }
                if device.isAggregate { tags.append(device.isStackedAggregate ? "multi-output" : "aggregate") }
                if device.isDisplaySpeaker { tags.append("display") }
                let tagText = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
                print("\(audio.displayName(for: device))\(tagText)\n    uid: \(device.uid)")
            }
        case "--status":
            printStatus(audio)
        case "--volume":
            guard args.count > 1, let percent = Float(args[1]), (0...100).contains(percent) else {
                return fail("--volume needs a number from 0 to 100")
            }
            guard audio.canControlVolume else { return fail("The current output has no volume control") }
            audio.setVolume(percent / 100)
            printStatus(audio)
        case "--up", "--down":
            guard audio.canControlVolume else { return fail("The current output has no volume control") }
            audio.stepVolume(up: command == "--up")
            printStatus(audio)
        case "--mute", "--unmute":
            audio.setMuted(command == "--mute")
            printStatus(audio)
        case "--use-displays":
            do {
                try audio.useAllDisplays()
                printStatus(audio)
            } catch {
                return fail(error.localizedDescription)
            }
        case "--select":
            guard args.count > 1 else { return fail("--select needs a device name or uid") }
            let query = args[1...].joined(separator: " ")
            guard let device = audio.devices.first(where: { $0.uid == query })
                ?? audio.devices.first(where: { audio.displayName(for: $0) == query })
                ?? audio.devices.first(where: { $0.name == query })
            else { return fail("No output device named “\(query)”. Try --list.") }
            guard audio.select(device) else { return fail("Could not select \(device.name)") }
            printStatus(audio)
        default:
            return fail("Unknown command \(command)\n\n\(usage)")
        }
        return 0
    }

    private static func printStatus(_ audio: AudioController) {
        audio.reload()
        guard let device = audio.defaultOutput else {
            print("Output: none")
            return
        }
        print("Output: \(audio.displayName(for: device))")
        let targets = audio.volumeTargets(for: device)
        if targets.isEmpty {
            print("Volume: not adjustable")
            return
        }
        print("Volume: \(Int((audio.volume * 100).rounded()))%\(audio.isMuted ? " (muted)" : "")")
        if targets.count > 1 || targets.first != device.id {
            for target in targets {
                let name = audio.devices.first { $0.id == target }.map(audio.displayName(for:)) ?? "Device \(target)"
                let level = DeviceVolume.volume(target).map { "\(Int(($0 * 100).rounded()))%" } ?? "?"
                let muted = DeviceVolume.isMuted(target) == true ? " (muted)" : ""
                print("  • \(name): \(level)\(muted)")
            }
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }
}
