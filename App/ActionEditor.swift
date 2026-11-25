import AppKit
import LoopCore
import LoupedeckKit
import SwiftUI
import UniformTypeIdentifiers

/// An ordered list of actions with add / remove / reorder.
struct ActionListEditor: View {
    let engine: Engine
    @Binding var actions: [Action]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions.indices, id: \.self) { i in
                ActionRow(engine: engine, action: $actions[i],
                          onDelete: { actions.remove(at: i) },
                          onMoveUp: i > 0 ? { actions.swapAt(i, i - 1) } : nil,
                          onMoveDown: i < actions.count - 1 ? { actions.swapAt(i, i + 1) } : nil)
            }
            Menu {
                ForEach(ActionTemplate.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items, id: \.title) { item in
                            Button(item.title) { actions.append(item.make()) }
                        }
                    }
                }
            } label: {
                Label(actions.isEmpty ? "Add Action" : "Add Another", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct ActionTemplate {
    let title: String
    let make: () -> Action

    static let groups: [(title: String, items: [ActionTemplate])] = [
        ("Integrations", [
            .init(title: "Keyboard Maestro Macro") { .keyboardMaestro(macro: "", parameter: nil) },
            .init(title: "BetterTouchTool Named Trigger") { .bttNamedTrigger(name: "", value: nil) },
            .init(title: "Alfred External Trigger") { .alfredTrigger(trigger: "", workflow: "", argument: nil) },
            .init(title: "Shortcuts") { .shortcut(name: "", input: nil) },
        ]),
        ("Keyboard & Media", [
            .init(title: "Keyboard Shortcut") { .keystroke(KeyStroke(key: "space", modifiers: [.command])) },
            .init(title: "Type Text") { .typeText("") },
            .init(title: "Media Key") { .media(.playPause) },
        ]),
        ("Open", [
            .init(title: "Open App") { .openApp(path: "") },
            .init(title: "Open URL") { .openURL("https://") },
        ]),
        ("Scripts", [
            .init(title: "Shell Command") { .shell(command: "") },
            .init(title: "AppleScript") { .appleScript(source: "") },
        ]),
        ("LoopDeLoop", [
            .init(title: "Go to Page") { .page(.next) },
            .init(title: "Switch Profile") { .profile(name: "") },
            .init(title: "Device Brightness") { .brightness(.adjust(0.1)) },
            .init(title: "Vibrate") { .vibrate(.short) },
            .init(title: "Wait") { .delay(seconds: 0.2) },
        ]),
    ]
}

struct ActionRow: View {
    let engine: Engine
    @Binding var action: Action
    let onDelete: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).frame(width: 18)
                Text(title).font(.headline)
                Spacer()
                if let onMoveUp { Button(action: onMoveUp) { Image(systemName: "chevron.up") }.buttonStyle(.borderless) }
                if let onMoveDown { Button(action: onMoveDown) { Image(systemName: "chevron.down") }.buttonStyle(.borderless) }
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            fields
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private var fields: some View {
        switch action {
        case .keystroke(let k):
            ShortcutRecorder(stroke: k) { action = .keystroke($0) }

        case .typeText(let text):
            TextField("Text to type", text: Binding(get: { text }, set: { action = .typeText($0) }), axis: .vertical)
                .textFieldStyle(.roundedBorder)

        case .openApp(let path):
            HStack {
                Text(path.isEmpty ? "No app chosen" : FileManager.default.displayName(atPath: path))
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url { action = .openApp(path: url.path) }
                }
            }

        case .openURL(let s):
            TextField("https://…", text: Binding(get: { s }, set: { action = .openURL($0) }))
                .textFieldStyle(.roundedBorder)

        case .shell(let command):
            CodeField(text: Binding(get: { command }, set: { action = .shell(command: $0) }),
                      hint: "Runs in zsh -l. Env: LOOPDELOOP_CONTROL, _PAGE, _PROFILE, _DELTA")

        case .appleScript(let source):
            CodeField(text: Binding(get: { source }, set: { action = .appleScript(source: $0) }), hint: nil)

        case .shortcut(let name, let input):
            HStack {
                TextField("Shortcut name", text: Binding(get: { name }, set: { action = .shortcut(name: $0, input: input) }))
                    .textFieldStyle(.roundedBorder)
                ShortcutsPicker { action = .shortcut(name: $0, input: input) }
            }
            TextField("Input (optional)", text: Binding(get: { input ?? "" }, set: { action = .shortcut(name: name, input: $0.isEmpty ? nil : $0) }))
                .textFieldStyle(.roundedBorder)

        case .bttNamedTrigger(let name, let value):
            TextField("Named trigger (BTT → Other → Named Triggers)", text: Binding(get: { name }, set: { action = .bttNamedTrigger(name: $0, value: value) }))
                .textFieldStyle(.roundedBorder)
            TextField("Value for variable loopdeloop_value (optional, e.g. {delta})",
                      text: Binding(get: { value ?? "" }, set: { action = .bttNamedTrigger(name: name, value: $0.isEmpty ? nil : $0) }))
                .textFieldStyle(.roundedBorder)

        case .keyboardMaestro(let macro, let parameter):
            HStack {
                TextField("Macro name or UID", text: Binding(get: { macro }, set: { action = .keyboardMaestro(macro: $0, parameter: parameter) }))
                    .textFieldStyle(.roundedBorder)
                KeyboardMaestroPicker { action = .keyboardMaestro(macro: $0, parameter: parameter) }
            }
            KMMacroName(uid: macro)
            TextField("Parameter → %TriggerValue% (optional, e.g. {delta})",
                      text: Binding(get: { parameter ?? "" }, set: { action = .keyboardMaestro(macro: macro, parameter: $0.isEmpty ? nil : $0) }))
                .textFieldStyle(.roundedBorder)

        case .alfredTrigger(let trigger, let workflow, let argument):
            TextField("Workflow bundle ID (e.g. com.you.workflow)", text: Binding(get: { workflow }, set: { action = .alfredTrigger(trigger: trigger, workflow: $0, argument: argument) }))
                .textFieldStyle(.roundedBorder)
            TextField("External trigger ID", text: Binding(get: { trigger }, set: { action = .alfredTrigger(trigger: $0, workflow: workflow, argument: argument) }))
                .textFieldStyle(.roundedBorder)
            TextField("Argument (optional)", text: Binding(get: { argument ?? "" }, set: { action = .alfredTrigger(trigger: trigger, workflow: workflow, argument: $0.isEmpty ? nil : $0) }))
                .textFieldStyle(.roundedBorder)

        case .media(let key):
            Picker("", selection: Binding(get: { key }, set: { action = .media($0) })) {
                ForEach(MediaKey.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()

        case .page(let target):
            PageTargetPicker(engine: engine, target: target) { action = .page($0) }

        case .profile(let name):
            Picker("", selection: Binding(get: { name }, set: { action = .profile(name: $0) })) {
                Text("Choose…").tag("")
                ForEach(engine.config.profiles) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()

        case .brightness(let change):
            BrightnessEditor(change: change) { action = .brightness($0) }

        case .vibrate(let pattern):
            Picker("", selection: Binding(get: { pattern }, set: { action = .vibrate($0) })) {
                ForEach(Haptic.allCases, id: \.self) { Text(String(describing: $0)).tag($0) }
            }
            .labelsHidden()

        case .delay(let seconds):
            Stepper(value: Binding(get: { seconds }, set: { action = .delay(seconds: max(0, $0)) }), in: 0...30, step: 0.1) {
                Text(String(format: "%.1f s", seconds)).monospacedDigit()
            }
        }
    }

    private var title: String {
        switch action {
        case .keystroke: "Keyboard Shortcut"
        case .typeText: "Type Text"
        case .openApp: "Open App"
        case .openURL: "Open URL"
        case .shell: "Shell Command"
        case .appleScript: "AppleScript"
        case .shortcut: "Shortcuts"
        case .bttNamedTrigger: "BetterTouchTool"
        case .keyboardMaestro: "Keyboard Maestro"
        case .alfredTrigger: "Alfred"
        case .media: "Media Key"
        case .page: "Go to Page"
        case .profile: "Switch Profile"
        case .brightness: "Device Brightness"
        case .vibrate: "Vibrate"
        case .delay: "Wait"
        }
    }

    private var icon: String {
        switch action {
        case .keystroke: "command"
        case .typeText: "character.cursor.ibeam"
        case .openApp: "app"
        case .openURL: "link"
        case .shell: "terminal"
        case .appleScript: "applescript"
        case .shortcut: "square.2.layers.3d"
        case .bttNamedTrigger: "hand.tap"
        case .keyboardMaestro: "keyboard"
        case .alfredTrigger: "magnifyingglass"
        case .media: "playpause"
        case .page: "rectangle.stack"
        case .profile: "person.crop.rectangle.stack"
        case .brightness: "sun.max"
        case .vibrate: "waveform"
        case .delay: "timer"
        }
    }
}

// MARK: - Field helpers

struct CodeField: View {
    @Binding var text: String
    let hint: String?
    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 60, maxHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
        if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
    }
}

/// Click "Record", press a key combination.
struct ShortcutRecorder: View {
    let stroke: KeyStroke
    let onChange: (KeyStroke) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(recording ? "Press a shortcut…" : stroke.description)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .frame(minWidth: 120, alignment: .leading)
            Spacer()
            Button(recording ? "Cancel" : "Record") { recording ? stop() : start() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let name = KeyCodes.name(for: event.keyCode) else { return nil }
            var mods: [KeyStroke.Modifier] = []
            let f = event.modifierFlags
            if f.contains(.command) { mods.append(.command) }
            if f.contains(.shift) { mods.append(.shift) }
            if f.contains(.option) { mods.append(.option) }
            if f.contains(.control) { mods.append(.control) }
            onChange(KeyStroke(key: name, modifiers: mods))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

extension KeyCodes {
    /// Preferred name for a key code (reverse of `code(for:)`).
    static func name(for code: UInt16) -> String? {
        let preferred = ["return", "escape", "delete"]
        let names = names.filter { self.code(for: $0) == code }
        return names.first(where: preferred.contains) ?? names.min { $0.count < $1.count }
    }
}

struct KeyboardMaestroPicker: View {
    let onPick: (String) -> Void
    @State private var macros: [(group: String, name: String, uid: String)] = []
    @State private var loaded = false

    var body: some View {
        Menu {
            if !loaded {
                Text("Loading…")
            } else if macros.isEmpty {
                Text("No macros (is the Keyboard Maestro Engine running?)")
            } else {
                ForEach(Dictionary(grouping: macros, by: \.group).sorted { $0.key < $1.key }, id: \.key) { group, items in
                    Menu(group) {
                        ForEach(items, id: \.uid) { m in Button(m.name) { onPick(m.uid) } }
                    }
                }
            }
        } label: { Image(systemName: "list.bullet") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Pick a macro (stored by UID, so renaming it in Keyboard Maestro won't break this)")
        .task {
            macros = await Integrations.keyboardMaestroMacros()
            loaded = true
        }
    }
}

/// Shows the macro name when the field holds a UID.
struct KMMacroName: View {
    let uid: String
    @State private var name: String?
    var body: some View {
        Group {
            if let name { Text("→ \(name)").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: uid) {
            guard uid.count == 36, uid.contains("-") else { name = nil; return }
            name = await Integrations.keyboardMaestroMacros().first { $0.uid == uid }?.name
        }
    }
}

struct ShortcutsPicker: View {
    let onPick: (String) -> Void
    @State private var names: [String] = []

    var body: some View {
        Menu {
            if names.isEmpty { Text("No shortcuts found") }
            ForEach(names, id: \.self) { n in Button(n) { onPick(n) } }
        } label: { Image(systemName: "list.bullet") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task {
            names = await Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["list"]
                let out = Pipe()
                p.standardOutput = out
                try? p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
            }.value
        }
    }
}

struct PageTargetPicker: View {
    let engine: Engine
    let target: PageTarget
    let onChange: (PageTarget) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { tag(target) }, set: { onChange(fromTag($0)) })) {
            Text("Next page").tag("next")
            Text("Previous page").tag("prev")
            Divider()
            ForEach(Array(engine.profile.pages.enumerated()), id: \.element.id) { i, p in
                Text("\(i + 1). \(p.name)").tag("name:\(p.name)")
            }
        }
        .labelsHidden()
    }

    private func tag(_ t: PageTarget) -> String {
        switch t {
        case .next: "next"
        case .previous: "prev"
        case .index(let i): engine.profile.pages.indices.contains(i) ? "name:\(engine.profile.pages[i].name)" : "next"
        case .named(let n): "name:\(n)"
        }
    }

    private func fromTag(_ s: String) -> PageTarget {
        if s == "next" { return .next }
        if s == "prev" { return .previous }
        return .named(String(s.dropFirst(5)))
    }
}

struct BrightnessEditor: View {
    let change: BrightnessChange
    let onChange: (BrightnessChange) -> Void

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { isSet }, set: { onChange($0 ? .set(0.5) : .adjust(0.1)) })) {
                Text("Change by").tag(false)
                Text("Set to").tag(true)
            }
            .labelsHidden()
            .frame(width: 110)
            Slider(value: Binding(get: { value }, set: { onChange(isSet ? .set($0) : .adjust($0)) }),
                   in: isSet ? 0...1 : -0.5...0.5, step: 0.1)
            Text("\(Int(value * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private var isSet: Bool { if case .set = change { true } else { false } }
    private var value: Double {
        switch change {
        case .set(let v), .adjust(let v): v
        }
    }
}
