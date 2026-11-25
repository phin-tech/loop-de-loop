import AppKit
import LoopCore
import LoupedeckKit
import SwiftUI
import UniformTypeIdentifiers

struct Inspector: View {
    let engine: Engine
    let selection: Selection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selection {
                case .key(let i): KeyInspector(engine: engine, index: i)
                case .button(let i): ButtonInspector(engine: engine, index: i)
                case .knob(let k): KnobInspector(engine: engine, knob: k)
                case nil: Text("Select a key, button or knob.").foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Key

struct KeyInspector: View {
    let engine: Engine
    let index: Int

    private var key: Binding<KeyConfig> {
        Binding(get: { engine.page.key(index) }, set: { v in engine.editPage { $0.setKey(index, v) } })
    }
    private var appearance: Binding<Appearance> { key.appearance }

    var body: some View {
        Text("Key \(index)").font(.title2.bold())

        HStack(alignment: .top, spacing: 14) {
            if let img = Renderer.keyImage(engine.effectiveAppearance(key: index), size: 90, images: engine.images) {
                Image(decorative: img, scale: 2)
                    .frame(width: 90, height: 90)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: optionalText(appearance.title))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    OptionalColorPicker(label: "Text", color: appearance.titleColor, fallback: Renderer.defaultTitleColor)
                    OptionalColorPicker(label: "Background", color: appearance.background, fallback: Renderer.defaultBackground)
                }
                HStack {
                    Text("Size")
                    Slider(value: Binding(get: { appearance.wrappedValue.fontSize ?? 0 },
                                          set: { appearance.wrappedValue.fontSize = $0 < 8 ? nil : $0 }), in: 0...36)
                    Text(appearance.wrappedValue.fontSize.map { "\(Int($0))" } ?? "auto")
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                .font(.caption)
            }
        }

        GroupBox("Graphic") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SymbolPickerButton(symbol: appearance.symbol,
                                       color: appearance.wrappedValue.symbolColor ?? appearance.wrappedValue.titleColor ?? .white)
                    OptionalColorPicker(label: "", color: appearance.symbolColor, fallback: .white)
                }
                TextField("…or type a symbol name", text: optionalText(appearance.symbol))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                if let symbol = appearance.wrappedValue.symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil {
                    Text("No SF Symbol named “\(symbol)”").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button(appearance.wrappedValue.image == nil ? "Choose Image…" : "Replace Image…") { chooseImage() }
                    if appearance.wrappedValue.image != nil {
                        Button("Remove Image") { appearance.wrappedValue.image = nil }
                    }
                    Spacer()
                    Text("An image replaces the symbol").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }

        BindingsEditor(engine: engine, bindings: key.actions, controlName: "key")

        Button("Clear Key", role: .destructive) { engine.editPage { $0.keys[String(index)] = nil } }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { appearance.wrappedValue.image = try engine.images.importImage(from: url) } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Round button

struct ButtonInspector: View {
    let engine: Engine
    let index: Int

    private var button: Binding<ButtonConfig> {
        Binding(get: { engine.page.button(index) }, set: { v in engine.editPage { $0.setButton(index, v) } })
    }

    var body: some View {
        Text("Round button \(index)").font(.title2.bold())
        HStack {
            Toggle("Light", isOn: Binding(get: { button.wrappedValue.color != nil },
                                          set: { button.wrappedValue.color = $0 ? .white : nil }))
            if button.wrappedValue.color != nil {
                ColorPicker("Color", selection: Binding(get: { Color(button.wrappedValue.color ?? .white) },
                                                        set: { button.wrappedValue.color = RGB($0) }), supportsOpacity: false)
            }
        }
        BindingsEditor(engine: engine, bindings: button.actions, controlName: "button")
    }
}

// MARK: - Knob

struct KnobInspector: View {
    let engine: Engine
    let knob: Knob

    private var config: Binding<KnobConfig> {
        Binding(get: { engine.page.knob(knob) }, set: { v in engine.editPage { $0.knobs[knob] = v } })
    }

    var body: some View {
        Text(knob.displayName).font(.title2.bold())
        TextField("Label on the side strip", text: optionalText(config.label))
            .textFieldStyle(.roundedBorder)

        GroupBox("Turn left (counter-clockwise)") {
            ActionListEditor(engine: engine, actions: config.left).padding(6)
        }
        GroupBox("Turn right (clockwise)") {
            ActionListEditor(engine: engine, actions: config.right).padding(6)
        }
        Text("Actions run once per notch. In text fields, {delta} is -1 or 1.")
            .font(.caption).foregroundStyle(.secondary)

        BindingsEditor(engine: engine, bindings: config.actions, controlName: "click")
    }
}

// MARK: - Press / hold / release

struct BindingsEditor: View {
    let engine: Engine
    @Binding var bindings: Bindings
    let controlName: String
    @State private var tab = 0

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Press (\(bindings.press.count))").tag(0)
                    Text("Hold (\(bindings.hold.count))").tag(1)
                    Text("Release (\(bindings.release.count))").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch tab {
                case 0: ActionListEditor(engine: engine, actions: $bindings.press)
                case 1:
                    ActionListEditor(engine: engine, actions: $bindings.hold)
                    Text("With hold actions, press actions wait for release, so a tap and a hold do different things.")
                        .font(.caption).foregroundStyle(.secondary)
                default: ActionListEditor(engine: engine, actions: $bindings.release)
                }
            }
            .padding(6)
        } label: {
            Text(controlName == "click" ? "Click" : "Actions")
        }
    }
}

// MARK: - Helpers

/// Binding that treats "" as nil.
func optionalText(_ b: Binding<String?>) -> Binding<String> {
    Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
}

struct OptionalColorPicker: View {
    let label: String
    @Binding var color: RGB?
    let fallback: RGB

    var body: some View {
        HStack(spacing: 4) {
            ColorPicker(label, selection: Binding(get: { Color(color ?? fallback) }, set: { color = RGB($0) }),
                        supportsOpacity: false)
            if color != nil {
                Button { color = nil } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .buttonStyle(.borderless)
                    .help("Use the default")
            }
        }
        .font(.caption)
    }
}
