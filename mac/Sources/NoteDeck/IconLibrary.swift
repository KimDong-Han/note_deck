import AppKit
import NoteDeckCore

/// Built-in icons = SVG files in <app>/Contents/Resources/icons (dev: mac/icons). Same names exist on the phone as ic_<name>.
enum IconLibrary {
    static let brand: Set<String> = ["claude"]          // coloured marks; mono marks render as templates

    static var directory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("icons"), FileManager.default.fileExists(atPath: r.path) { return r }
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../../icons").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static var names: [String] {
        guard let d = directory, let files = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return [] }
        let generic = files.filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) }
        let order = ["laptop", "headphones", "mute", "volume", "key"]
        let brandNames = generic.filter { brand.contains($0) }.sorted()
        let rest = generic.filter { !brand.contains($0) }.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        return rest + brandNames
    }

    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let c = cache[name] { return c }
        guard let d = directory, let img = NSImage(contentsOf: d.appendingPathComponent("\(name).svg")) else { return nil }
        img.isTemplate = !brand.contains(name)
        cache[name] = img
        return img
    }
}

