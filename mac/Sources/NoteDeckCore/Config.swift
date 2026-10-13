import Foundation
import CryptoKit

/// User config. Keys are snake_case in the JSON file.
public struct Config: Codable, Equatable {
    public struct MIDI: Codable, Equatable {
        /// Case-insensitive substring of the MIDI source/destination name. Empty = every source.
        public var deviceMatch: String = ""
        /// 1...16, or 0 for any channel.
        public var channel: Int = 0
    }
    public struct Feedback: Codable, Equatable {
        public var enabled: Bool = true
        /// CC number used to report current output volume (0..127) back to the phone.
        public var volumeCc: Int = 7
    }
    public struct Action: Codable, Equatable {
        public var type: String
        public var device: String?
        public var on: Bool?
        public var delta: Int?
        public var value: Int?
        public var app: String?
        public var url: String?
        public var path: String?
        public var command: String?
        public var script: String?
        public var name: String?
        public var key: String?
        public var mods: [String]?
        public var title: String?
        public var message: String?
        public init(type: String) { self.type = type }
    }
    public struct Trigger: Codable, Equatable {
        public var name: String?
        public var actions: [Action]
        public init(name: String?, actions: [Action]) { self.name = name; self.actions = actions }
    }
    /// One deck button (3x2 grid on the phone). `note` defaults to 60 + index.
    public struct DeckButton: Codable, Equatable, Identifiable {
        public var id: Int { note }
        public var note: Int
        public var label: String
        /// Built-in icon name on the phone (laptop, headphones, mute, volume, play, …) — ignored when glyph is set.
        public var icon: String
        /// Emoji / short text drawn instead of the icon.
        public var glyph: String?
        /// Custom icon: base64 PNG (<=128px), pushed to the phone over SysEx.
        public var image: String?
        public var enabled: Bool
        /// Fixed buttons keep their actions; label/icon stay editable.
        public var fixed: Bool
        public var actions: [Action]
        public init(note: Int, label: String, icon: String, glyph: String? = nil, image: String? = nil, enabled: Bool = true, fixed: Bool = false, actions: [Action]) {
            self.note = note; self.label = label; self.icon = icon; self.glyph = glyph; self.image = image
            self.enabled = enabled; self.fixed = fixed; self.actions = actions
        }
        /// Which icon source is in effect.
        public var iconKind: String { if image != nil { return "image" }; if let g = glyph, !g.isEmpty { return "glyph" }; return "builtin" }
        /// Stable short hash of the image payload (phone uses it to skip re-downloads).
        public var imageHash: String? {
            guard let img = image else { return nil }
            return SHA256.hash(data: Data(img.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }

    public var midi = MIDI()
    public var feedback = Feedback()
    /// Deck buttons sent to the phone (max 9, 3x3). Missing in old configs -> defaults.
    public var buttons: [DeckButton]? = nil
    /// Extra raw triggers ("cc:7", "note:70"...) for anything outside the deck grid.
    public var triggers: [String: Trigger] = [:]

    public init() {}

    public static let maxButtons = 9          // 3x3 grid; only enabled buttons are shown on the phone
    public static let firstNote = 60
    public static let volumeCC = 7

    public static func defaultButtons() -> [DeckButton] {
        var out = Action(type: "audio_output"); out.device = "MacBook"
        var usb = Action(type: "audio_output"); usb.device = "USB-Audio"
        let mute = Action(type: "mute_toggle")
        return [
            DeckButton(note: 60, label: "Mac Speaker", icon: "laptop", fixed: true, actions: [out]),
            DeckButton(note: 61, label: "USB Audio", icon: "headphones", fixed: true, actions: [usb]),
            DeckButton(note: 62, label: "Mute", icon: "mute", fixed: true, actions: [mute]),
        ] + (4...9).map { DeckButton(note: Config.firstNote + $0 - 1, label: "버튼 \($0)", icon: "key", enabled: false, actions: []) }
    }

    /// Buttons padded/normalised to exactly `maxButtons`, fixed rows kept as defaults.
    public var normalizedButtons: [DeckButton] {
        let defaults = Config.defaultButtons()
        var list = buttons ?? defaults
        if list.count < Config.maxButtons { list += defaults[list.count...] }
        if list.count > Config.maxButtons { list = Array(list.prefix(Config.maxButtons)) }
        for i in list.indices { list[i].note = Config.firstNote + i; if i < 3 { list[i].fixed = true; list[i].enabled = true } }
        return list
    }

    /// Note triggers from deck buttons + extra triggers. Deck buttons win on conflicts.
    public var effectiveTriggers: [String: Trigger] {
        var t = triggers
        for b in normalizedButtons where b.enabled {
            t[TriggerKey.make(.note, b.note)] = Trigger(name: b.label, actions: b.actions)
        }
        return t
    }

    /// Layout JSON the phone renders.
    public func phoneLayoutJSON() -> Data {
        var buttons: [[String: Any]] = []
        for b in normalizedButtons where b.enabled {
            var o: [String: Any] = ["label": b.label, "icon": b.icon, "note": b.note]
            if let g = b.glyph, !g.isEmpty { o["glyph"] = g }
            if let h = b.imageHash { o["has_image"] = true; o["image_hash"] = h }
            buttons.append(o)
        }
        let obj: [String: Any] = ["columns": 3, "columns_land": 3, "buttons": buttons,
                                  "slider": ["label": "Volume", "cc": feedback.volumeCc]]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

public enum ConfigStore {
    public static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NoteDeck")
    public static let fileURL = directory.appendingPathComponent("config.json")

    public static func load() throws -> Config {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            var c = Config()
            c.buttons = Config.defaultButtons()
            c.triggers["cc:\(Config.volumeCC)"] = Config.Trigger(name: "Volume", actions: [Config.Action(type: "volume_set")])
            try save(c)
            Log.info("wrote default config to \(fileURL.path)")
        }
        let data = try Data(contentsOf: fileURL)
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        var cfg = try dec.decode(Config.self, from: data)
        if cfg.buttons == nil {                 // migrate old trigger-only config
            cfg.buttons = Config.defaultButtons()
            for k in ["note:60", "note:61", "note:62"] { cfg.triggers.removeValue(forKey: k) }
            try save(cfg)
            Log.info("migrated config: added deck buttons")
        }
        return cfg
    }

    public static func save(_ cfg: Config) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: fileURL, options: .atomic)
    }

    public static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}

/// "note:60" -> (.note, 60)
public enum TriggerKey {
    public enum Kind: String { case note, cc }
    public static func parse(_ key: String) -> (Kind, Int)? {
        let parts = key.lowercased().split(separator: ":")
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])), let n = Int(parts[1]) else { return nil }
        return (kind, n)
    }
    public static func make(_ kind: Kind, _ n: Int) -> String { "\(kind.rawValue):\(n)" }
}
