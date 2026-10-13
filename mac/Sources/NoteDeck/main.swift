import AppKit
import SwiftUI
import NoteDeckCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var model: DeckModel?
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.echoToStdout = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let img = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Note Deck") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "ND"
        }
        menu.delegate = self
        statusItem.menu = menu
        engine.onStatusChanged = { [weak self] in self?.updateIcon() }
        engine.start()
        let model = DeckModel(engine: engine)
        self.model = model
        engine.onStatusChanged = { [weak self] in
            self?.updateIcon()
            model.syncFromEngine()
            model.objectWillChange.send()
        }
        showWindow()
        Log.info("NoteDeck started")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    @objc func showWindow() {
        guard let model = model else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 500),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Note Deck"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DeckEditorView(model: model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.info("window shown: visible=\(window?.isVisible ?? false) frame=\(window?.frame ?? .zero) screen=\(NSScreen.main?.frame ?? .zero)")
    }

    func updateIcon() {
        statusItem.button?.appearsDisabled = engine.midi.connectedSources.isEmpty
        statusItem.button?.toolTip = "Note Deck · " + (engine.midi.connectedSources.first ?? "MIDI 대기 중")
    }

    // Build menu fresh every time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let srcs = engine.midi.connectedSources
        menu.addItem(label(srcs.isEmpty ? "MIDI: 연결된 장치 없음" : "MIDI: " + srcs.joined(separator: ", ")))
        menu.addItem(label("출력: " + engine.outputSummary))
        menu.addItem(label("최근: " + engine.lastEvent))
        menu.addItem(.separator())

        let outMenu = NSMenu()
        let cur = engine.audio.defaultOutput()
        for d in engine.audio.outputDevices() {
            let it = NSMenuItem(title: d.name, action: #selector(pickOutput(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = d.id; it.state = d.id == cur ? .on : .off
            outMenu.addItem(it)
        }
        let outItem = NSMenuItem(title: "출력 장치", action: nil, keyEquivalent: "")
        outItem.submenu = outMenu
        menu.addItem(outItem)

        let trigMenu = NSMenu()
        for key in engine.config.triggers.keys.sorted() {
            let t = engine.config.triggers[key]!
            let it = NSMenuItem(title: "\(key)  \(t.name ?? "")", action: #selector(fireTrigger(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = key
            trigMenu.addItem(it)
        }
        let trigItem = NSMenuItem(title: "트리거 실행 (테스트)", action: nil, keyEquivalent: "")
        trigItem.submenu = trigMenu
        menu.addItem(trigItem)
        menu.addItem(.separator())

        menu.addItem(item("설정 창 열기", #selector(showWindow)))
        menu.addItem(item("설정 파일 열기", #selector(openConfig)))
        menu.addItem(item("설정 다시 읽기", #selector(reload)))
        menu.addItem(item("로그 열기", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("종료", #selector(quit), key: "q"))
    }

    private func label(_ s: String) -> NSMenuItem { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    private func item(_ s: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self; return i
    }

    @objc func pickOutput(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UInt32 { engine.audio.setDefaultOutput(id) }
    }
    @objc func fireTrigger(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { engine.fire(key, value: key.hasPrefix("cc") ? 100 : 127) }
    }
    @objc func openConfig() {
        _ = try? ConfigStore.load()
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }
    @objc func reload() { engine.reloadConfig() }
    @objc func openLog() { NSWorkspace.shared.open(Log.fileURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
