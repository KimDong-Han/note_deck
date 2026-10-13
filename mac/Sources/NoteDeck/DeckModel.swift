import AppKit
import Combine
import NoteDeckCore

final class DeckModel: ObservableObject {
    @Published var config: Config
    @Published var selected: Int = 3
    @Published var shortcuts: [String] = []
    let engine: Engine
    private var saveTimer: Timer?

    init(engine: Engine) {
        self.engine = engine
        var c = engine.config
        c.buttons = c.normalizedButtons
        config = c
        loadShortcuts()
    }

    var buttons: [Config.DeckButton] {
        get { config.buttons ?? [] }
        set { config.buttons = newValue; scheduleSave() }
    }

    func button(_ i: Int) -> Config.DeckButton { buttons[i] }
    func update(_ i: Int, _ f: (inout Config.DeckButton) -> Void) {
        var list = buttons
        f(&list[i])
        buttons = list
    }

    /// Called when the engine reloaded the file (e.g. edited by hand). Skip while our own save is pending.
    func syncFromEngine() {
        guard saveTimer == nil else { return }
        var c = engine.config
        c.buttons = c.normalizedButtons
        if c != config { config = c }
    }

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.saveTimer = nil
            self?.saveNow()
        }
    }

    func saveNow() {
        do { try ConfigStore.save(config) } catch { Log.error("save config: \(error)") }
        // engine notices the file change within 1s and pushes the layout; do it now for snappier feedback
        engine.reloadConfig()
    }

    func test(_ i: Int) { engine.fire(TriggerKey.make(.note, buttons[i].note), value: 127) }

    func loadShortcuts() {
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts"); p.arguments = ["list"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            let names = String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
            DispatchQueue.main.async { self.shortcuts = names }
        }
    }

    func pickImage(for i: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg, .tiff, .gif, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "버튼 아이콘으로 쓸 이미지"
        guard panel.runModal() == .OK, let url = panel.url, let b64 = ImageTools.encodeIcon(from: url) else { return }
        update(i) { $0.image = b64; $0.glyph = nil }
    }

    func pickApp(for i: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        update(i) { var a = $0.actions.first ?? Config.Action(type: "open"); a.type = "open"; a.app = name; $0.actions = [a] }
    }
}
