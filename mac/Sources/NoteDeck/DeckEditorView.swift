import SwiftUI
import ServiceManagement
import NoteDeckCore

struct DeckEditorView: View {
    @ObservedObject var model: DeckModel

    var body: some View {
        HStack(spacing: 0) {
            GridPane(model: model).frame(minWidth: 420)
            Divider()
            InspectorPane(model: model).frame(width: 340)
        }
        .frame(minWidth: 800, minHeight: 540)
    }
}

// MARK: - left: status + 3x2 grid

struct GridPane: View {
    @ObservedObject var model: DeckModel
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(model.engine.midi.connectedSources.isEmpty ? Color.red : Color.green).frame(width: 9, height: 9)
                Text(model.engine.midi.connectedSources.isEmpty ? "폰 연결 안 됨 (USB → MIDI 모드)" : "폰 연결됨: " + model.engine.midi.connectedSources.joined(separator: ", "))
                    .font(.callout)
                Spacer()
                Text(model.engine.outputSummary).font(.callout).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(0..<Config.maxButtons, id: \.self) { i in
                    TileView(button: model.button(i), selected: model.selected == i)
                        .onTapGesture { model.selected = i }
                }
            }
            Text("윗줄 3개는 동작이 고정돼 있고 이름·아이콘만 바꿀 수 있습니다. 나머지 6개는 자유롭게 설정하고, 켠 버튼만 폰에 나타납니다(최대 3×3).")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            LoginItemToggle()
        }
        .padding(18)
    }
}

struct TileView: View {
    let button: Config.DeckButton
    let selected: Bool

    var body: some View {
        VStack(spacing: 10) {
            IconView(button: button, size: 34)
            Text(button.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).frame(height: 96)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: selected ? 2.5 : 1))
        .opacity(button.enabled ? 1 : 0.35)
        .contentShape(Rectangle())
    }
}

struct IconView: View {
    let button: Config.DeckButton
    let size: CGFloat

    var body: some View {
        Group {
            if let b64 = button.image, let img = ImageTools.image(base64: b64) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
            } else if let g = button.glyph, !g.isEmpty {
                Text(g).font(.system(size: size * 0.85))
            } else if let img = IconLibrary.image(button.icon) {
                Image(nsImage: img).resizable().renderingMode(IconLibrary.brand.contains(button.icon) ? .original : .template).scaledToFit()
            } else {
                Image(systemName: "questionmark.square.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - right: inspector

struct InspectorPane: View {
    @ObservedObject var model: DeckModel

    var i: Int { model.selected }
    var btn: Config.DeckButton { model.button(i) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("버튼 \(i + 1)" + (btn.fixed ? "  ·  동작 고정" : "")).font(.title3.bold())

                GroupBox("표시") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("이름") {
                            TextField("이름", text: Binding(get: { btn.label }, set: { v in model.update(i) { $0.label = v } }))
                                .textFieldStyle(.roundedBorder)
                        }
                        Picker("아이콘", selection: Binding(get: { btn.iconKind }, set: { setIconKind($0) })) {
                            Text("내장").tag("builtin"); Text("이모지").tag("glyph"); Text("이미지").tag("image")
                        }.pickerStyle(.segmented)

                        switch btn.iconKind {
                        case "glyph":
                            TextField("이모지 또는 짧은 글자", text: Binding(get: { btn.glyph ?? "" }, set: { v in model.update(i) { $0.glyph = v } }))
                                .textFieldStyle(.roundedBorder)
                        case "image":
                            HStack {
                                IconView(button: btn, size: 44)
                                Button("이미지 바꾸기…") { model.pickImage(for: i) }
                                Button("제거") { model.update(i) { $0.image = nil } }
                            }
                            Text(imageHint(btn)).font(.caption).foregroundStyle(.secondary)
                        default:
                            BuiltinIconPicker(selected: btn.icon) { name in model.update(i) { $0.icon = name; $0.glyph = nil; $0.image = nil } }
                        }
                    }.padding(6)
                }

                GroupBox("동작") {
                    VStack(alignment: .leading, spacing: 10) {
                        if btn.fixed {
                            Text(describe(btn.actions)).foregroundStyle(.secondary)
                        } else {
                            Toggle("이 버튼 사용", isOn: Binding(get: { btn.enabled }, set: { v in model.update(i) { $0.enabled = v } }))
                            ActionEditor(model: model, index: i)
                        }
                        Button("지금 실행해 보기") { model.test(i) }
                    }.padding(6)
                }
            }
            .padding(18)
        }
    }

    private func imageHint(_ b: Config.DeckButton) -> String {
        guard let img = b.image else { return "PNG/JPG/GIF/SVG, 128px로 줄여서 폰에 보냅니다" }
        let kb = img.count * 3 / 4 / 1024
        let sec = ImageTools.transferSeconds(base64: img)
        let kind = ImageTools.isGIF(base64: img) ? "움직이는 GIF, 폰에서 재생" : "PNG"
        return "\(kind) · \(kb) KB · USB 전송 약 \(sec)초" + (sec > 10 ? " — 프레임이 적은 GIF가 빠릅니다" : "")
    }

    private func setIconKind(_ kind: String) {
        switch kind {
        case "glyph": model.update(i) { $0.image = nil; if ($0.glyph ?? "").isEmpty { $0.glyph = "⭐️" } }
        case "image": model.pickImage(for: i)
        default: model.update(i) { $0.glyph = nil; $0.image = nil }
        }
    }

    private func describe(_ actions: [Config.Action]) -> String {
        actions.map { a in
            switch a.type {
            case "audio_output": return "출력 장치 → \(a.device ?? "")"
            case "audio_input": return "입력 장치 → \(a.device ?? "")"
            case "mute_toggle": return "음소거 토글"
            default: return a.type
            }
        }.joined(separator: ", ")
    }
}

struct BuiltinIconPicker: View {
    let selected: String
    let onPick: (String) -> Void
    private let cols = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(IconLibrary.names, id: \.self) { name in
                IconView(button: Config.DeckButton(note: 0, label: "", icon: name, actions: []), size: 26)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(name == selected ? Color.accentColor.opacity(0.25) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(name == selected ? Color.accentColor : Color.gray.opacity(0.3)))
                    .help(name)
                    .onTapGesture { onPick(name) }
            }
        }
    }
}

// MARK: - action editor (one action per custom button)

struct ActionEditor: View {
    @ObservedObject var model: DeckModel
    let index: Int

    static let types: [(String, String)] = [
        ("open_app", "앱 열기"), ("open_url", "URL 열기"), ("open_path", "파일/폴더 열기"),
        ("shell", "셸 명령"), ("shortcut", "단축어 실행"), ("keystroke", "키 입력"),
        ("audio_output", "출력 장치 전환"), ("audio_input", "입력 장치 전환"), ("mute_toggle", "음소거 토글"),
        ("applescript", "AppleScript"), ("notify", "알림 띄우기"),
        ("display_sleep", "화면 끄기 (Mac + 폰)"), ("display_wake", "화면 켜기"),
    ]

    private var action: Config.Action { model.button(index).actions.first ?? Config.Action(type: "open_app") }

    /// GUI type: open_* are all "open" in config, distinguished by which field is set.
    private var guiType: String {
        let a = action
        if a.type == "open" { return a.url != nil ? "open_url" : a.path != nil ? "open_path" : "open_app" }
        return a.type
    }

    private func set(_ f: (inout Config.Action) -> Void) {
        model.update(index) { b in var a = b.actions.first ?? Config.Action(type: "open"); f(&a); b.actions = [a] }
    }

    private func setType(_ t: String) {
        set { a in
            a = Config.Action(type: t.hasPrefix("open_") ? "open" : t)
            switch t {
            case "open_url": a.url = "https://"
            case "open_path": a.path = "~/"
            case "open_app": a.app = ""
            case "keystroke": a.key = ""; a.mods = ["cmd"]
            case "shell": a.command = ""
            case "shortcut": a.name = model.shortcuts.first
            case "audio_output", "audio_input": a.device = ""
            case "applescript": a.script = ""
            case "notify": a.message = ""
            default: break
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("동작", selection: Binding(get: { guiType }, set: { setType($0) })) {
                ForEach(ActionEditor.types, id: \.0) { Text($0.1).tag($0.0) }
            }
            switch guiType {
            case "open_app":
                HStack {
                    TextField("앱 이름 (예: Safari)", text: Binding(get: { action.app ?? "" }, set: { v in set { $0.app = v } })).textFieldStyle(.roundedBorder)
                    Button("선택…") { model.pickApp(for: index) }
                }
            case "open_url":
                TextField("https://…", text: Binding(get: { action.url ?? "" }, set: { v in set { $0.url = v } })).textFieldStyle(.roundedBorder)
            case "open_path":
                TextField("~/Documents", text: Binding(get: { action.path ?? "" }, set: { v in set { $0.path = v } })).textFieldStyle(.roundedBorder)
            case "shell":
                TextField("zsh 명령", text: Binding(get: { action.command ?? "" }, set: { v in set { $0.command = v } })).textFieldStyle(.roundedBorder)
            case "shortcut":
                Picker("단축어", selection: Binding(get: { action.name ?? "" }, set: { v in set { $0.name = v } })) {
                    ForEach(model.shortcuts, id: \.self) { Text($0).tag($0) }
                }
            case "keystroke":
                HStack {
                    TextField("키 (예: f13, a, space)", text: Binding(get: { action.key ?? "" }, set: { v in set { $0.key = v } })).textFieldStyle(.roundedBorder)
                }
                HStack {
                    ForEach(["cmd", "alt", "ctrl", "shift"], id: \.self) { m in
                        Toggle(m == "alt" ? "⌥" : m == "cmd" ? "⌘" : m == "ctrl" ? "⌃" : "⇧",
                               isOn: Binding(get: { action.mods?.contains(m) ?? false },
                                             set: { on in set { var s = Set($0.mods ?? []); if on { s.insert(m) } else { s.remove(m) }; $0.mods = Array(s) } }))
                            .toggleStyle(.button)
                    }
                }
                Text("키 입력은 시스템 설정 → 손쉬운 사용에서 NoteDeck을 허용해야 동작합니다.").font(.caption).foregroundStyle(.secondary)
            case "audio_output", "audio_input":
                let devs = guiType == "audio_output" ? model.engine.audio.outputDevices() : model.engine.audio.inputDevices()
                Picker("장치", selection: Binding(get: { action.device ?? "" }, set: { v in set { $0.device = v } })) {
                    Text("선택…").tag("")
                    ForEach(devs, id: \.id) { Text($0.name).tag($0.name) }
                }
            case "applescript":
                TextEditor(text: Binding(get: { action.script ?? "" }, set: { v in set { $0.script = v } })).frame(height: 80).font(.system(.body, design: .monospaced))
            case "notify":
                TextField("메시지", text: Binding(get: { action.message ?? "" }, set: { v in set { $0.message = v } })).textFieldStyle(.roundedBorder)
            case "display_sleep":
                Text("Mac 모니터를 끄고 폰 화면도 검게 합니다. 폰을 터치하거나 Mac이 깨어나면 돌아옵니다.").font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }
}


/// "Open at login" via SMAppService (System Settings → General → Login Items shows the same switch).
struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { enabled }, set: { set($0) }))
                .toggleStyle(.switch)
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
        }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            enabled = SMAppService.mainApp.status == .enabled
            error = nil
        } catch {
            self.error = "설정 실패: \(error.localizedDescription)"
            enabled = SMAppService.mainApp.status == .enabled
        }
    }
}
