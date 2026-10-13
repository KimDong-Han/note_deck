import Foundation
import CoreGraphics
import CoreAudio
import Carbon.HIToolbox

/// Executes config actions. `value` is the CC value (0..127) when the trigger was a CC.
public final class ActionRunner {
    let audio: AudioController
    /// Set by Engine: tells the phone to black out (false) or wake (true).
    public var onPhoneScreen: ((Bool) -> Void)?
    public init(audio: AudioController) { self.audio = audio }

    public func run(_ actions: [Config.Action], value: Int?) {
        for a in actions { run(a, value: value) }
    }

    public func run(_ a: Config.Action, value: Int?) {
        switch a.type {
        case "audio_output":
            guard let d = audio.find(a.device ?? "", output: true) else { Log.warn("audio_output: no device matching '\(a.device ?? "")'"); return }
            audio.setDefaultOutput(d.id); Log.info("output -> \(d.name)")
        case "audio_input":
            guard let d = audio.find(a.device ?? "", output: false) else { Log.warn("audio_input: no device matching '\(a.device ?? "")'"); return }
            audio.setDefaultInput(d.id); Log.info("input -> \(d.name)")
        case "mute_toggle":
            guard let id = target(a) else { return }
            let m = audio.isMuted(id) ?? false
            audio.setMuted(!m, of: id); Log.info("mute -> \(!m)")
        case "mute":
            guard let id = target(a) else { return }
            audio.setMuted(a.on ?? true, of: id)
        case "volume_set":
            guard let id = target(a) else { return }
            let v = a.value ?? value ?? 0            // config value (0..127) or CC value
            audio.setVolume(Float(v) / 127.0, of: id)
        case "volume_step":
            guard let id = target(a), let cur = audio.volume(of: id) else { return }
            let step = Float(a.delta ?? 6) / 100.0   // delta in percent
            audio.setVolume(cur + step, of: id)
        case "open":
            if let app = a.app { shell("/usr/bin/open", ["-a", app]) }
            else if let url = a.url { shell("/usr/bin/open", [url]) }
            else if let p = a.path { shell("/usr/bin/open", [(p as NSString).expandingTildeInPath]) }
        case "shell":
            guard let c = a.command else { return }
            shell("/bin/zsh", ["-lc", c])
        case "applescript":
            guard let s = a.script else { return }
            shell("/usr/bin/osascript", ["-e", s])
        case "shortcut":
            guard let n = a.name else { return }
            shell("/usr/bin/shortcuts", ["run", n])
        case "keystroke":
            guard let k = a.key else { return }
            keystroke(k, mods: a.mods ?? [])
        case "display_sleep":
            // Mac displays off; Engine's screensDidSleep observer then blacks out the phone too.
            shell("/usr/bin/pmset", ["displaysleepnow"])
        case "display_wake":
            shell("/usr/bin/caffeinate", ["-u", "-t", "2"])
        case "phone_screen":
            onPhoneScreen?(a.on ?? true)
        case "notify":
            let t = (a.title ?? "Note Deck").replacingOccurrences(of: "\"", with: "\\\"")
            let m = (a.message ?? "").replacingOccurrences(of: "\"", with: "\\\"")
            shell("/usr/bin/osascript", ["-e", "display notification \"\(m)\" with title \"\(t)\""])
        default:
            Log.warn("unknown action type '\(a.type)'")
        }
    }

    private func target(_ a: Config.Action) -> AudioDeviceID? {
        if let d = a.device, !d.isEmpty { return audio.find(d, output: true)?.id }
        return audio.defaultOutput()
    }

    private func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); Log.info("run \(path) \(args.joined(separator: " "))") }
        catch { Log.error("run \(path): \(error)") }
    }

    // MARK: keystroke (needs Accessibility permission)
    private func keystroke(_ key: String, mods: [String]) {
        guard let code = KeyCodes.map[key.lowercased()] else { Log.warn("keystroke: unknown key '\(key)'"); return }
        var flags: CGEventFlags = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        Log.info("keystroke \(mods.joined(separator: "+"))+\(key)")
    }
}

enum KeyCodes {
    static let map: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
            "space": 49, "`": 50, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105, "f16": 106, "f14": 107,
            "f10": 109, "f12": 111, "f15": 113, "f17": 64, "f18": 79, "f19": 80, "f20": 90, "f1": 122, "f2": 120, "f4": 118,
            "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        return m
    }()
}
