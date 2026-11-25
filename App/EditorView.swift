import AppKit
import LoopCore
import LoupedeckKit
import SwiftUI

/// What's selected on the device picture.
enum Selection: Hashable {
    case key(Int)
    case button(Int)
    case knob(Knob)
}

struct EditorView: View {
    let engine: Engine
    @State private var selection: Selection? = .key(0)
    @State private var showSettings = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                EditorToolbar(engine: engine, showSettings: $showSettings)
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    DeviceCanvas(engine: engine, selection: $selection)
                        .padding(32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                StatusBar(engine: engine)
            }
            .frame(minWidth: 720, minHeight: 560)

            Inspector(engine: engine, selection: selection)
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 520)
        }
        .sheet(isPresented: $showSettings) { SettingsView(engine: engine) }
    }
}

// MARK: - Toolbar: profiles and pages

struct EditorToolbar: View {
    let engine: Engine
    @Binding var showSettings: Bool
    @State private var renaming: RenameTarget?
    @State private var newName = ""
    @State private var showApps = false

    enum RenameTarget: Identifiable {
        case profile, page(Int)
        var id: String { if case .page(let i) = self { "page\(i)" } else { "profile" } }
    }

    var body: some View {
        HStack(spacing: 12) {
            Picker("Profile", selection: Binding(get: { engine.profileID }, set: { engine.setProfile($0) })) {
                ForEach(engine.config.profiles) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 220)

            Menu {
                Button("New Profile") { addProfile() }
                Button("Duplicate Profile") { duplicateProfile() }
                Button("Rename Profile…") { newName = engine.profile.name; renaming = .profile }
                Button("Switch Automatically for Apps…") { showApps = true }
                Divider()
                Button("Make Default Profile") { engine.edit { $0.defaultProfileID = engine.profileID } }
                    .disabled(engine.config.defaultProfileID == engine.profileID)
                Button("Delete Profile", role: .destructive) { deleteProfile() }
                    .disabled(engine.config.profiles.count < 2)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(engine.profile.pages.enumerated()), id: \.element.id) { i, page in
                        Button { engine.goToPage(.index(i)) } label: {
                            Text("\(i + 1). \(page.name)")
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(i == engine.pageIndex ? Color.accentColor.opacity(0.25) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename…") { newName = page.name; renaming = .page(i) }
                            Button("Duplicate") { duplicatePage(i) }
                            Button("Move Left") { movePage(i, by: -1) }.disabled(i == 0)
                            Button("Move Right") { movePage(i, by: 1) }.disabled(i == engine.profile.pages.count - 1)
                            Divider()
                            Button("Delete", role: .destructive) { deletePage(i) }.disabled(engine.profile.pages.count < 2)
                        }
                    }
                    Button { addPage() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a page")
                }
            }

            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { applyRename() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showApps) { ProfileAppsSheet(engine: engine) }
    }

    private func applyRename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let target = renaming else { return }
        switch target {
        case .profile: engine.editProfile { $0.name = name }
        case .page(let i): engine.editProfile { $0.pages[i].name = name }
        }
    }

    private func addProfile() {
        let p = Profile(name: "Profile \(engine.config.profiles.count + 1)", pages: [Page(name: "Home")])
        engine.edit { $0.profiles.append(p) }
        engine.setProfile(p.id)
    }

    private func duplicateProfile() {
        var p = engine.profile
        p.id = UUID()
        p.name += " copy"
        p.appBundleIDs = []
        p.pages = p.pages.map { var g = $0; g.id = UUID(); return g }
        engine.edit { $0.profiles.append(p) }
        engine.setProfile(p.id)
    }

    private func deleteProfile() {
        let id = engine.profileID
        guard let next = engine.config.profiles.first(where: { $0.id != id }) else { return }
        engine.setProfile(next.id)
        engine.edit { c in
            c.profiles.removeAll { $0.id == id }
            if c.defaultProfileID == id { c.defaultProfileID = c.profiles[0].id }
        }
    }

    private func addPage() {
        engine.editProfile { $0.pages.append(Page(name: "Page \($0.pages.count + 1)")) }
        engine.goToPage(.index(engine.profile.pages.count - 1))
    }

    private func duplicatePage(_ i: Int) {
        engine.editProfile { p in
            var g = p.pages[i]
            g.id = UUID()
            g.name += " copy"
            p.pages.insert(g, at: i + 1)
        }
    }

    private func movePage(_ i: Int, by d: Int) {
        engine.editProfile { $0.pages.swapAt(i, i + d) }
        if engine.pageIndex == i { engine.goToPage(.index(i + d)) }
    }

    private func deletePage(_ i: Int) {
        if engine.pageIndex >= i, engine.pageIndex > 0 { engine.goToPage(.index(engine.pageIndex - 1)) }
        engine.editProfile { $0.pages.remove(at: i) }
    }
}

// MARK: - Device picture

struct DeviceCanvas: View {
    let engine: Engine
    @Binding var selection: Selection?

    private let keySize: CGFloat = 90
    private var model: LoupedeckModel { engine.model }

    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                knobColumn([.topLeft, .centerLeft, .bottomLeft])
                screen
                knobColumn([.topRight, .centerRight, .bottomRight])
            }
            HStack(spacing: 16) {
                ForEach(0..<model.roundButtons, id: \.self) { i in roundButton(i) }
            }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 26).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.black.opacity(0.4)))
        .shadow(radius: 12, y: 6)
    }

    private var screen: some View {
        HStack(spacing: 0) {
            strip([.topLeft, .centerLeft, .bottomLeft])
            VStack(spacing: 0) {
                ForEach(0..<model.rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<model.columns, id: \.self) { col in key(row * model.columns + col) }
                    }
                }
            }
            strip([.topRight, .centerRight, .bottomRight])
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func key(_ i: Int) -> some View {
        let appearance = engine.effectiveAppearance(key: i)
        let selected = selection == .key(i)
        let pressed = engine.pressed.contains("key:\(i)")
        return ZStack {
            if let img = Renderer.keyImage(appearance, size: model.keySize, images: engine.images) {
                Image(decorative: img, scale: 2).interpolation(.high)
            }
            if appearance.isEmpty {
                Text("\(i)").font(.caption2).foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: keySize, height: keySize)
        .overlay(RoundedRectangle(cornerRadius: 10).inset(by: 2)
            .stroke(selected ? Color.accentColor : pressed ? .white : .clear, lineWidth: 3))
        .contentShape(Rectangle())
        .onTapGesture { selection = .key(i) }
        .help("Key \(i)")
    }

    private func strip(_ knobs: [Knob]) -> some View {
        VStack(spacing: 0) {
            ForEach(knobs, id: \.self) { k in
                let label = engine.page.knob(k).label ?? ""
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(width: 60, height: keySize)
                    .background(label.isEmpty ? Color.clear : Color(white: 0.12))
                    .overlay(Rectangle().stroke(selection == .knob(k) ? Color.accentColor : .clear, lineWidth: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = .knob(k) }
            }
        }
    }

    private func knobColumn(_ knobs: [Knob]) -> some View {
        VStack(spacing: keySize - 56) {
            ForEach(knobs, id: \.self) { k in
                let selected = selection == .knob(k)
                let pressed = engine.pressed.contains("knob:\(k.rawValue)")
                Circle()
                    .fill(AngularGradient(colors: [Color(white: 0.35), Color(white: 0.18), Color(white: 0.35)], center: .center))
                    .overlay(Circle().stroke(selected ? Color.accentColor : pressed ? .white : Color.black.opacity(0.5),
                                             lineWidth: selected || pressed ? 3 : 1))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                    .onTapGesture { selection = .knob(k) }
                    .help(k.displayName)
            }
        }
    }

    private func roundButton(_ i: Int) -> some View {
        let color = engine.page.button(i).color
        let selected = selection == .button(i)
        let pressed = engine.pressed.contains("button:\(i)")
        return Circle()
            .fill(Color(white: 0.22))
            .overlay(Circle().inset(by: 4).stroke(color.map(Color.init) ?? Color(white: 0.3), lineWidth: 3))
            .overlay(Circle().stroke(selected ? Color.accentColor : pressed ? .white : .clear, lineWidth: 3))
            .frame(width: 42, height: 42)
            .overlay(Text("\(i)").font(.caption2).foregroundStyle(.white.opacity(0.6)))
            .contentShape(Circle())
            .onTapGesture { selection = .button(i) }
    }
}

struct StatusBar: View {
    let engine: Engine
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(engine.isConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(statusText).font(.callout)
            if let error = engine.lastError {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(1).truncationMode(.middle)
                Button("Clear") { engine.clearError() }.buttonStyle(.link)
            }
            Spacer()
            Text("Changes save automatically").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var statusText: String {
        switch engine.status {
        case .searching: "Looking for a Loupedeck…"
        case .recovering: "Reconnecting…"
        case .connected(let name, let fw): "\(name) · firmware \(fw)"
        }
    }
}

extension Knob {
    var displayName: String {
        switch self {
        case .topLeft: "Top-left knob"
        case .centerLeft: "Middle-left knob"
        case .bottomLeft: "Bottom-left knob"
        case .topRight: "Top-right knob"
        case .centerRight: "Middle-right knob"
        case .bottomRight: "Bottom-right knob"
        }
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

extension RGB {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(UInt8((ns.redComponent * 255).rounded()), UInt8((ns.greenComponent * 255).rounded()),
                  UInt8((ns.blueComponent * 255).rounded()))
    }
}
