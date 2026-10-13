import Foundation
import CoreMIDI
import NoteDeckCore

// notedeck-cli: test helper that pretends to be the phone.
//   notedeck-cli note <n> [velocity]     send Note On (+ Note Off) from a virtual source "NoteDeck Test"
//   notedeck-cli cc <n> <value>          send Control Change
//   notedeck-cli listen [seconds]        create a virtual destination and print feedback the app sends
//   notedeck-cli midi                    list MIDI sources/destinations
//   notedeck-cli audio                   list audio devices
//   notedeck-cli fire <trigger> [value]  run a trigger directly (no MIDI), e.g. fire note:62
//   notedeck-cli icon <note> <imagefile>  set a deck button's icon from a PNG/JPG/GIF (GIF keeps animation) and enable it

let args = Array(CommandLine.arguments.dropFirst())
Log.echoToStdout = false

func usage() -> Never {
    print("usage: notedeck-cli note <n> [vel] | cc <n> <val> | listen [sec] | midi | audio | fire <trigger> [value] | icon <note> <file>")
    exit(2)
}

func midiName(_ ep: MIDIEndpointRef) -> String {
    var cf: Unmanaged<CFString>? = nil
    if MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
    return "endpoint \(ep)"
}

guard let cmd = args.first else { usage() }

switch cmd {
case "midi":
    print("sources:")
    for i in 0..<MIDIGetNumberOfSources() { print("  - " + midiName(MIDIGetSource(i))) }
    print("destinations:")
    for i in 0..<MIDIGetNumberOfDestinations() { print("  - " + midiName(MIDIGetDestination(i))) }

case "audio":
    let a = AudioController()
    let out = a.defaultOutput(), inp = a.defaultInput()
    for d in a.allDevices() {
        var tags: [String] = []
        if d.hasOutput { tags.append(d.id == out ? "OUTPUT*" : "output") }
        if d.hasInput { tags.append(d.id == inp ? "INPUT*" : "input") }
        let vol = d.hasOutput ? (a.volume(of: d.id).map { " vol=\(Int(($0 * 100).rounded()))%" } ?? "") : ""
        let mute = d.hasOutput ? ((a.isMuted(d.id) ?? false) ? " muted" : "") : ""
        print("  - \(d.name)  [\(tags.joined(separator: ","))]\(vol)\(mute)")
    }

case "fire":
    guard args.count >= 2 else { usage() }
    let e = Engine()
    e.reloadConfig()
    e.fire(args[1], value: args.count >= 3 ? Int(args[2]) : nil)
    Thread.sleep(forTimeInterval: 0.3)

case "icon":
    guard args.count >= 3, let note = Int(args[1]) else { usage() }
    guard let b64 = ImageTools.encodeIcon(from: URL(fileURLWithPath: args[2])) else { print("could not read image"); exit(1) }
    var cfg = try ConfigStore.load()
    var list = cfg.normalizedButtons
    guard let i = list.firstIndex(where: { $0.note == note }) else { print("no button with note \(note)"); exit(1) }
    list[i].image = b64; list[i].glyph = nil; list[i].enabled = true
    cfg.buttons = list
    try ConfigStore.save(cfg)
    print("button \(i + 1) (note \(note)) icon set: \(ImageTools.isGIF(base64: b64) ? "animated gif" : "png"), \(b64.count) base64 chars")

case "note", "cc":
    guard args.count >= 2, let n = Int(args[1]) else { usage() }
    let v = args.count >= 3 ? Int(args[2]) ?? 127 : (cmd == "note" ? 127 : 100)
    var client = MIDIClientRef(); var src = MIDIEndpointRef()
    MIDIClientCreate("NoteDeck CLI" as CFString, nil, nil, &client)
    MIDISourceCreateWithProtocol(client, "NoteDeck Test" as CFString, ._1_0, &src)
    Thread.sleep(forTimeInterval: 0.6)  // let the app connect to the new source
    func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        var list = MIDIEventList()
        let p = MIDIEventListInit(&list, ._1_0)
        var w: UInt32 = 0x2000_0000 | (UInt32(status) << 16) | (UInt32(d1) << 8) | UInt32(d2)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, p, 0, 1, &w)
        MIDIReceivedEventList(src, &list)
    }
    if cmd == "note" {
        send(0x90, UInt8(n & 0x7F), UInt8(v & 0x7F)); Thread.sleep(forTimeInterval: 0.05); send(0x80, UInt8(n & 0x7F), 0)
        print("sent note \(n) vel \(v)")
    } else {
        send(0xB0, UInt8(n & 0x7F), UInt8(v & 0x7F)); print("sent cc \(n) = \(v)")
    }
    Thread.sleep(forTimeInterval: 0.3)
    MIDIEndpointDispose(src)

case "listen":
    let secs = args.count >= 2 ? Double(args[1]) ?? 5 : 5
    var client = MIDIClientRef(); var dest = MIDIEndpointRef()
    MIDIClientCreate("NoteDeck CLI" as CFString, nil, nil, &client)
    MIDIDestinationCreateWithProtocol(client, "NoteDeck Test" as CFString, ._1_0, &dest) { list, _ in
        for packet in list.unsafeSequence() {
            for w in umpWords(packet) where (w >> 28) == 0x2 {
                let st = (w >> 16) & 0xFF, d1 = (w >> 8) & 0x7F, d2 = w & 0x7F
                let kind = st & 0xF0 == 0x90 ? "noteOn" : st & 0xF0 == 0x80 ? "noteOff" : st & 0xF0 == 0xB0 ? "cc" : String(format: "0x%02X", st)
                print("recv \(kind) \(d1) \(d2)"); fflush(stdout)
            }
        }
    }
    print("listening as 'NoteDeck Test' for \(Int(secs))s…"); fflush(stdout)
    RunLoop.main.run(until: Date().addingTimeInterval(secs))
    MIDIEndpointDispose(dest)

default:
    usage()
}
