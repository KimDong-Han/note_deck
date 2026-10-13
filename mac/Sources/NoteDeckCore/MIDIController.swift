import Foundation
import CoreMIDI

/// CoreMIDI in/out. Connects to every source whose display name matches `deviceMatch`
/// (empty = all), reconnects on hot-plug, and sends feedback to matching destinations.
public final class MIDIController {
    public struct Message {
        public let status: UInt8   // e.g. 0x90 note on ch1
        public let data1: UInt8
        public let data2: UInt8
        public var channel: Int { Int(status & 0x0F) + 1 }
        public var kind: UInt8 { status & 0xF0 }
        public let source: String
    }

    public var deviceMatch: String = "" { didSet { if deviceMatch != oldValue { reconnect() } } }
    /// Called on main queue.
    public var onMessage: ((Message) -> Void)?
    public var onSourcesChanged: (([String]) -> Void)?
    public private(set) var connectedSources: [String] = []

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []
    private var sourceNames: [MIDIEndpointRef: String] = [:]

    public init() {}

    public func start() {
        var st = MIDIClientCreateWithBlock("NoteDeck" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.reconnect() }
            }
        }
        guard st == noErr else { Log.error("MIDIClientCreate -> \(st)"); return }

        st = MIDIInputPortCreateWithProtocol(client, "NoteDeck In" as CFString, ._1_0, &inPort) { [weak self] list, refCon in
            self?.handle(list, refCon: refCon)
        }
        guard st == noErr else { Log.error("MIDIInputPortCreate -> \(st)"); return }

        st = MIDIOutputPortCreate(client, "NoteDeck Out" as CFString, &outPort)
        if st != noErr { Log.error("MIDIOutputPortCreate -> \(st)") }
        reconnect()
    }

    public func reconnect() {
        for src in connected { MIDIPortDisconnectSource(inPort, src) }
        connected = []; sourceNames = [:]
        let match = deviceMatch.lowercased()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            let name = displayName(src)
            if !match.isEmpty && !name.lowercased().contains(match) { continue }
            let st = MIDIPortConnectSource(inPort, src, UnsafeMutableRawPointer(bitPattern: Int(src)))
            if st == noErr { connected.append(src); sourceNames[src] = name }
            else { Log.warn("connect \(name) -> \(st)") }
        }
        connectedSources = connected.compactMap { sourceNames[$0] }
        Log.info("MIDI sources: \(connectedSources.isEmpty ? "(none)" : connectedSources.joined(separator: ", "))")
        onSourcesChanged?(connectedSources)
    }

    public func destinations() -> [(MIDIEndpointRef, String)] {
        let match = deviceMatch.lowercased()
        return (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let d = MIDIGetDestination(i); let n = displayName(d)
            if !match.isEmpty && !n.lowercased().contains(match) { return nil }
            return (d, n)
        }
    }

    /// Send one MIDI 1.0 channel-voice message to every matching destination.
    public func send(status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        let word: UInt32 = 0x2000_0000 | (UInt32(status) << 16) | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F)
        for (dest, _) in destinations() {
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            var w = word
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &w)
            MIDISendEventList(outPort, dest, &list)
        }
    }

    /// Send a SysEx message (bytes must start with 0xF0 and end with 0xF7) to every matching destination.
    public func sendSysEx(_ bytes: [UInt8]) {
        guard bytes.first == 0xF0, bytes.last == 0xF7, bytes.count < 60_000 else { Log.warn("bad sysex"); return }
        let size = bytes.count + 256
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var packet = MIDIPacketListInit(list)
        packet = MIDIPacketListAdd(list, size, packet, 0, bytes.count, bytes)
        for (dest, _) in destinations() { MIDISend(outPort, dest, list) }
    }

    public func noteOn(_ note: Int, velocity: Int = 127, channel: Int = 1) { send(status: 0x90 | UInt8((channel - 1) & 0x0F), UInt8(note & 0x7F), UInt8(velocity & 0x7F)) }
    public func noteOff(_ note: Int, channel: Int = 1) { send(status: 0x80 | UInt8((channel - 1) & 0x0F), UInt8(note & 0x7F), 0) }
    public func cc(_ num: Int, _ value: Int, channel: Int = 1) { send(status: 0xB0 | UInt8((channel - 1) & 0x0F), UInt8(num & 0x7F), UInt8(value & 0x7F)) }

    // MARK: - private
    private func displayName(_ ep: MIDIEndpointRef) -> String {
        var cf: Unmanaged<CFString>? = nil
        if MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        return "endpoint \(ep)"
    }

    private func handle(_ list: UnsafePointer<MIDIEventList>, refCon: UnsafeMutableRawPointer?) {
        let src = MIDIEndpointRef(Int(bitPattern: refCon))
        let name = sourceNames[src] ?? "?"
        for packet in list.unsafeSequence() {
            var words = umpWords(packet)
            while !words.isEmpty {
                let w = words.removeFirst()
                let type = w >> 28
                let extra: Int
                switch type {
                case 0x0, 0x1, 0x2, 0x6, 0x7: extra = 0
                case 0x3, 0x4, 0x8, 0x9, 0xA: extra = 1
                case 0xB, 0xC: extra = 2
                default: extra = 3
                }
                if extra > 0 { words.removeFirst(min(extra, words.count)) }
                guard type == 0x2 else { continue }
                let msg = Message(status: UInt8((w >> 16) & 0xFF), data1: UInt8((w >> 8) & 0x7F), data2: UInt8(w & 0x7F), source: name)
                DispatchQueue.main.async { self.onMessage?(msg) }
            }
        }
    }
}

/// Copy the UMP words out of a MIDIEventPacket (its `words` field is a 64-element tuple).
public func umpWords(_ packet: UnsafePointer<MIDIEventPacket>) -> [UInt32] {
    let count = min(Int(packet.pointee.wordCount), 64)
    return withUnsafePointer(to: packet.pointee.words) { ptr in
        ptr.withMemoryRebound(to: UInt32.self, capacity: 64) { Array(UnsafeBufferPointer(start: $0, count: count)) }
    }
}
