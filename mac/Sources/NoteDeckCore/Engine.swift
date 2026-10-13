import Foundation
import AppKit

/// Wires config + MIDI + audio + actions, and pushes feedback (active output / mute / volume) to the phone.
public final class Engine {
    /// Phone sends CC 119 after connecting; Mac answers with the full state.
    public static let syncRequestCC = 119
    public let audio = AudioController()
    public let midi = MIDIController()
    public private(set) var config = Config()
    public let runner: ActionRunner
    public var onStatusChanged: (() -> Void)?
    public private(set) var lastEvent: String = "-"

    private var configDate: Date?
    private var pollTimer: Timer?
    private var lastSentVolume: Int = -1
    private var lastSentNotes: [Int: Bool] = [:]

    /// Mac -> phone: CC 116, 0 = black out the phone screen, 1 = wake it.
    public static let phoneScreenCC = 116
    public private(set) var screensAsleep = false

    public init() {
        runner = ActionRunner(audio: audio)
        runner.onPhoneScreen = { [weak self] on in self?.setPhoneScreen(on: on) }
    }

    public func setPhoneScreen(on: Bool) {
        midi.cc(Engine.phoneScreenCC, on ? 1 : 0)
        Log.info("phone screen -> \(on ? "on" : "off")")
    }

    private func observeDisplaySleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true
            self?.setPhoneScreen(on: false)
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false
            self?.setPhoneScreen(on: true)
        }
    }

    public func start() {
        observeDisplaySleep()
        reloadConfig()
        audio.onChange = { [weak self] in self?.sendFeedback(); self?.onStatusChanged?() }
        audio.startListening()
        midi.onMessage = { [weak self] m in self?.handle(m) }
        midi.onSourcesChanged = { [weak self] _ in self?.sendFeedback(force: true); self?.onStatusChanged?() }
        midi.start()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.pollConfig() }
        sendFeedback(force: true)
    }

    public func reloadConfig() {
        do {
            config = try ConfigStore.load()
            configDate = ConfigStore.modificationDate()
            midi.deviceMatch = config.midi.deviceMatch
            Log.info("config loaded: \(config.effectiveTriggers.count) triggers, device_match='\(config.midi.deviceMatch)'")
            pushLayout()
            sendFeedback(force: true)
            onStatusChanged?()
        } catch {
            Log.error("config error: \(error)")
            lastEvent = "설정 파일 오류: \(error.localizedDescription)"
            onStatusChanged?()
        }
    }

    private func pollConfig() {
        guard let d = ConfigStore.modificationDate(), d != configDate else { return }
        Log.info("config changed on disk, reloading")
        reloadConfig()
    }

    /// Fire a trigger by key ("note:60", "cc:7") as if it came from MIDI.
    public func fire(_ key: String, value: Int?) {
        guard let t = config.effectiveTriggers[key] else { Log.info("no trigger for \(key)"); lastEvent = "\(key) (매핑 없음)"; onStatusChanged?(); return }
        lastEvent = "\(key) → \(t.name ?? "")" + (value.map { " [\($0)]" } ?? "")
        Log.info("trigger \(key) '\(t.name ?? "")' value=\(value.map(String.init) ?? "-")")
        if screensAsleep && !t.actions.contains(where: { $0.type == "display_sleep" }) {
            runner.run(Config.Action(type: "display_wake"), value: nil)
        }
        runner.run(t.actions, value: value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.sendFeedback(); self?.onStatusChanged?() }
    }

    private func handle(_ m: MIDIController.Message) {
        if config.midi.channel != 0 && m.channel != config.midi.channel { return }
        switch m.kind {
        case 0x90 where m.data2 > 0:
            fire(TriggerKey.make(.note, Int(m.data1)), value: Int(m.data2))
        case 0xB0 where Int(m.data1) == Engine.imageRequestCC:
            pushImage(note: Int(m.data2))
        case 0xB0 where Int(m.data1) == Engine.imageAckCC:
            handleAck()
        case 0xB0 where Int(m.data1) == Engine.syncRequestCC:
            Log.info("sync request from \(m.source)")
            pushLayout(force: true)
            sendFeedback(force: true)
        case 0xB0:
            fire(TriggerKey.make(.cc, Int(m.data1)), value: Int(m.data2))
        default:
            break // note off etc.
        }
    }

    // MARK: layout push (phone draws what the Mac says)
    /// SysEx: F0 7D 'N' 'D' <cmd> [note] <base64 payload> F7.  cmd 1 = layout JSON, cmd 2 = button image PNG.
    private var sentImageHash: [Int: String] = [:]
    /// Small chunks + wait for the phone's ACK: the phone's USB-MIDI receive buffer (~16 KB) overflows otherwise.
    static let chunkChars = 3_000
    public static let imageRequestCC = 118   // phone -> Mac: value = note, "send me this button's image"
    public static let imageAckCC = 117       // phone -> Mac: value = chunk index & 0x7F, "got it, next"
    private struct Transfer { let note: Int; let hash: String; let chars: [UInt8]; var next = 0; var total: Int { max(1, (chars.count + chunkChars - 1) / chunkChars) } }
    private var transfer: Transfer?
    private var queue: [Int] = []
    private var ackTimer: Timer?

    /// cmd 1 = layout JSON (with image hashes). Images go only when their hash changed since the last push,
    /// or when the phone asks for them (CC 118) — so reconnecting never re-sends what the phone already has.
    public func pushLayout(force: Bool = false) {
        let layout = config.phoneLayoutJSON()
        midi.sendSysEx(Engine.sysex(cmd: 1, header: [], payload: Array(layout.base64EncodedString().utf8)))
        var queued = 0
        for b in config.normalizedButtons where b.enabled {
            guard let h = b.imageHash else { sentImageHash[b.note] = nil; continue }
            if sentImageHash[b.note] == h { continue }
            if force && sentImageHash[b.note] == nil { continue }   // phone will request if it lacks the file
            pushImage(note: b.note); queued += 1
        }
        Log.info("layout pushed (\(layout.count) bytes, \(queued) images queued)")
    }

    /// Queue one button's image; chunks go out one at a time, each after the phone's ACK.
    public func pushImage(note: Int) {
        if transfer?.note == note {                  // in flight: restart with the *current* image (config may have changed)
            Log.info("image for note \(note): restarting from chunk 0")
            ackTimer?.invalidate()
            transfer = nil
            queue.removeAll { $0 == note }
            queue.insert(note, at: 0)
            startNextTransfer(); return
        }
        if queue.contains(note) { return }
        queue.append(note)
        startNextTransfer()
    }

    private func startNextTransfer() {
        guard transfer == nil, !queue.isEmpty else { return }
        let note = queue.removeFirst()
        guard let b = config.normalizedButtons.first(where: { $0.note == note }), let img = b.image, let h = b.imageHash else { startNextTransfer(); return }
        transfer = Transfer(note: note, hash: h, chars: Array(img.utf8))
        Log.info("image for note \(note): \(img.count) chars, \(transfer!.total) chunks")
        sendCurrentChunk()
    }

    private func sendCurrentChunk() {
        guard let t = transfer else { return }
        let idx = t.next, total = t.total
        let slice = Array(t.chars[idx * Engine.chunkChars ..< min(t.chars.count, (idx + 1) * Engine.chunkChars)])
        // header: note, idxHi, idxLo, totalHi, totalLo (7-bit each)
        midi.sendSysEx(Engine.sysex(cmd: 2, header: [UInt8(t.note & 0x7F), UInt8((idx >> 7) & 0x7F), UInt8(idx & 0x7F), UInt8((total >> 7) & 0x7F), UInt8(total & 0x7F)], payload: slice))
        ackTimer?.invalidate()
        ackTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self, let t = self.transfer else { return }
            Log.warn("image for note \(t.note): no ACK for chunk \(t.next), aborting")
            self.transfer = nil
            self.startNextTransfer()
        }
    }

    private func handleAck() {
        guard var t = transfer else { return }
        t.next += 1
        if t.next >= t.total {
            ackTimer?.invalidate()
            sentImageHash[t.note] = t.hash
            Log.info("image for note \(t.note) sent (\(t.total) chunks)")
            transfer = nil
            startNextTransfer()
        } else {
            transfer = t
            sendCurrentChunk()
        }
    }

    static func sysex(cmd: UInt8, header: [UInt8], payload: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [0xF0, 0x7D, 0x4E, 0x44, cmd]
        b += header
        b += payload
        b.append(0xF7)
        return b
    }

    // MARK: feedback  (phone LEDs / fader follow the Mac)
    public func sendFeedback(force: Bool = false) {
        guard config.feedback.enabled else { return }
        let out = audio.defaultOutput()
        let outName = out.map { audio.name(of: $0).lowercased() } ?? ""
        let inName = audio.defaultInput().map { audio.name(of: $0).lowercased() } ?? ""
        let muted = out.flatMap { audio.isMuted($0) } ?? false

        for (key, t) in config.effectiveTriggers {
            guard let (kind, n) = TriggerKey.parse(key), kind == .note else { continue }
            var state: Bool? = nil
            for a in t.actions {
                switch a.type {
                case "audio_output": state = (state ?? false) || matches(outName, a.device)
                case "audio_input": state = (state ?? false) || matches(inName, a.device)
                case "mute_toggle", "mute": state = (state ?? false) || muted
                default: break
                }
            }
            if let s = state, force || lastSentNotes[n] != s {
                lastSentNotes[n] = s
                s ? midi.noteOn(n) : midi.noteOff(n)
            }
        }
        if let out = out, let v = audio.volume(of: out) {
            let v127 = Int((v * 127).rounded())
            if force || v127 != lastSentVolume { lastSentVolume = v127; midi.cc(config.feedback.volumeCc, v127) }
        }
    }

    private func matches(_ name: String, _ match: String?) -> Bool {
        guard let m = match?.lowercased(), !m.isEmpty else { return false }
        return name == m || name.contains(m)
    }

    // MARK: status for UI
    public var outputSummary: String {
        guard let id = audio.defaultOutput() else { return "출력 없음" }
        let name = audio.name(of: id)
        let vol = audio.volume(of: id).map { " \(Int(($0 * 100).rounded()))%" } ?? ""
        let mute = (audio.isMuted(id) ?? false) ? " (음소거)" : ""
        return name + vol + mute
    }
}
