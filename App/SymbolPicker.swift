import AppKit
import LoopCore
import SwiftUI

/// SF Symbols names, search keywords and categories, read from the system's CoreGlyphs
/// bundle (the same data the SF Symbols app uses). There's no public API that lists
/// symbols, so if Apple moves these files we fall back to a short built-in list.
struct SymbolCatalog: Sendable {
    struct Category: Identifiable, Hashable, Sendable {
        let key: String
        let icon: String
        var id: String { key }
        var title: String {
            switch key {
            case "all": "All"
            case "whatsnew": "What's New"
            case "multicolor": "Multicolor"
            case "variable": "Variable"
            case "draw": "Draw"
            case "communication": "Communication"
            case "objectsandtools": "Objects & Tools"
            case "devices": "Devices"
            case "cameraandphotos": "Camera & Photos"
            case "connectivity": "Connectivity"
            case "transportation": "Transportation"
            case "automotive": "Automotive"
            case "accessibility": "Accessibility"
            case "privacyandsecurity": "Privacy & Security"
            case "human": "Human"
            case "home": "Home"
            case "fitness": "Fitness"
            case "nature": "Nature"
            case "editing": "Editing"
            case "textformatting": "Text Formatting"
            case "media": "Media"
            case "keyboard": "Keyboard"
            case "commerce": "Commerce"
            case "time": "Time"
            case "health": "Health"
            case "shapes": "Shapes"
            case "arrows": "Arrows"
            case "indices": "Indices"
            case "math": "Math"
            case "gaming": "Gaming"
            case "weather": "Weather"
            default: key.prefix(1).uppercased() + key.dropFirst()
            }
        }
    }

    let names: [String]
    let keywords: [String: [String]]
    let categoriesByName: [String: Set<String>]
    let categories: [Category]

    static let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Localized script variants (".ar", ".hi", ".zh.traditional", …) only add noise to a picker.
    static let localeSuffixes: Set<String> = [
        "ar", "he", "hi", "ja", "ko", "th", "zh", "rtl", "bn", "gu", "kn", "ml", "mr", "or", "pa", "ta", "te",
        "km", "my", "si", "el", "ru", "sat", "mni", "traditional", "my", "lo", "ur", "fa",
    ]

    static func load() -> SymbolCatalog {
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: resources.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        guard let order = plist("symbol_order.plist") as? [String], !order.isEmpty else { return .fallback }

        let names = order.filter { name in
            let parts = name.split(separator: ".")
            return parts.count < 2 || !localeSuffixes.contains(String(parts.last!))
        }
        let keywords = plist("symbol_search.plist") as? [String: [String]] ?? [:]
        let rawCategories = plist("symbol_categories.plist") as? [String: [String]] ?? [:]
        let categoriesByName = rawCategories.mapValues(Set.init)
        let categories = (plist("categories.plist") as? [[String: String]] ?? []).compactMap { entry -> Category? in
            guard let key = entry["key"], let icon = entry["icon"] else { return nil }
            return Category(key: key, icon: icon)
        }
        return SymbolCatalog(names: names, keywords: keywords, categoriesByName: categoriesByName,
                             categories: categories.isEmpty ? [Category(key: "all", icon: "square.grid.2x2")] : categories)
    }

    static let fallback = SymbolCatalog(
        names: [
            "play.fill", "pause.fill", "playpause.fill", "stop.fill", "forward.fill", "backward.fill", "speaker.wave.2.fill",
            "speaker.slash.fill", "mic.fill", "mic.slash.fill", "video.fill", "camera.fill", "music.note", "headphones",
            "folder.fill", "doc.fill", "terminal.fill", "keyboard", "command", "globe", "safari", "envelope.fill",
            "message.fill", "phone.fill", "bell.fill", "calendar", "clock.fill", "timer", "lightbulb.fill", "sun.max.fill",
            "moon.fill", "lock.fill", "lock.open.fill", "house.fill", "gearshape.fill", "magnifyingglass", "star.fill",
            "heart.fill", "bolt.fill", "flame.fill", "arrow.left", "arrow.right", "arrow.up", "arrow.down",
            "arrow.clockwise", "arrow.counterclockwise", "chevron.left", "chevron.right", "plus", "minus", "xmark",
            "checkmark", "trash.fill", "square.and.arrow.up", "camera.viewfinder", "display", "laptopcomputer",
            "desktopcomputer", "printer.fill", "wifi", "antenna.radiowaves.left.and.right", "cloud.fill", "paintbrush.fill",
            "pencil", "scissors", "hammer.fill", "wrench.fill", "cpu", "memorychip", "power", "rectangle.stack.fill",
        ],
        keywords: [:], categoriesByName: [:], categories: [Category(key: "all", icon: "square.grid.2x2")]
    )

    static let synonyms: [String: [String]] = [
        "off": ["slash"], "mute": ["slash"], "muted": ["slash"], "disable": ["slash"], "disabled": ["slash"],
        "volume": ["speaker"], "sound": ["speaker"], "audio": ["speaker", "waveform"],
        "close": ["xmark"], "cancel": ["xmark"], "delete": ["trash", "delete"], "remove": ["minus", "trash"],
        "add": ["plus"], "new": ["plus"], "settings": ["gearshape"], "preferences": ["gearshape"],
        "screenshot": ["camera.viewfinder", "viewfinder"], "search": ["magnifyingglass"], "find": ["magnifyingglass"],
        "next": ["forward", "chevron.right"], "previous": ["backward", "chevron.left"], "back": ["backward", "chevron.left"],
        "light": ["lightbulb", "sun"], "brightness": ["sun"], "email": ["envelope"], "mail": ["envelope"],
        "chat": ["message", "bubble"], "terminal": ["terminal", "apple.terminal"], "code": ["chevron.left.forwardslash"],
        "record": ["record.circle", "smallcircle.filled"], "folder": ["folder"], "file": ["doc"], "home": ["house"],
    ]

    /// Names in `category` matching every word of `query` (in the name or Apple's keywords).
    /// Name matches rank above keyword-only matches.
    func search(_ query: String, category: String) -> [String] {
        let pool = category == "all" ? names : names.filter { categoriesByName[$0]?.contains(category) == true }
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !terms.isEmpty else { return pool }
        // Everyday words for SF Symbols' naming ("mic off" → mic.slash).
        let alternatives = terms.map { [$0] + (Self.synonyms[$0] ?? []) }
        var inName: [String] = [], inKeywords: [String] = []
        for name in pool {
            let words = keywords[name] ?? []
            var allInName = true, allMatch = true
            for alts in alternatives {
                if alts.contains(where: name.contains) { continue }
                allInName = false
                if !words.contains(where: { w in alts.contains(where: w.contains) }) { allMatch = false; break }
            }
            if allInName { inName.append(name) } else if allMatch { inKeywords.append(name) }
        }
        // Shorter names first among name matches: "speaker" before "speaker.wave.2.circle.fill".
        return inName.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count } + inKeywords
    }
}

@MainActor
@Observable
final class SymbolLibrary {
    static let shared = SymbolLibrary()
    private(set) var catalog: SymbolCatalog?
    private(set) var recents: [String] = UserDefaults.standard.stringArray(forKey: "recentSymbols") ?? []

    func load() async {
        guard catalog == nil else { return }
        catalog = await Task.detached(priority: .userInitiated) { SymbolCatalog.load() }.value
    }

    func noteUsed(_ name: String) {
        recents.removeAll { $0 == name }
        recents.insert(name, at: 0)
        recents = Array(recents.prefix(16))
        UserDefaults.standard.set(recents, forKey: "recentSymbols")
    }
}

/// The button in the key inspector: shows the current symbol, opens the picker.
struct SymbolPickerButton: View {
    @Binding var symbol: String?
    var color: RGB = .white
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 8) {
                Group {
                    if let s = symbol, NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil {
                        Image(systemName: s)
                    } else {
                        Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
                Text(symbol ?? "Choose Symbol…").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .popover(isPresented: $open, arrowEdge: .leading) {
            SymbolPicker(selection: $symbol, color: color) { open = false }
        }
    }
}

struct SymbolPicker: View {
    @Binding var selection: String?
    let color: RGB
    let done: () -> Void

    @State private var library = SymbolLibrary.shared
    @State private var query = ""
    @State private var category = "all"
    @State private var results: [String] = []
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 52, maximum: 60), spacing: 6)]

    var body: some View {
        HStack(spacing: 0) {
            categoryList
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search symbols (e.g. volume, mic, arrow)", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { if let first = results.first { pick(first) } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                if query.isEmpty, category == "all", !library.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(library.recents, id: \.self) { cell($0) } }
                        }
                    }
                }

                if library.catalog == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    Text("No symbols match “\(query)”").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(results, id: \.self) { cell($0) }
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack {
                    Text(selection ?? "No symbol").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("\(results.count) symbols").font(.caption).foregroundStyle(.secondary)
                    if selection != nil { Button("Remove") { selection = nil; done() } }
                }
            }
            .padding(10)
        }
        .frame(width: 600, height: 480)
        .task {
            await library.load()
            refresh()
            searchFocused = true
        }
        .onChange(of: query) { refresh() }
        .onChange(of: category) { refresh() }
    }

    private var categoryList: some View {
        List(selection: Binding(get: { category }, set: { category = $0 ?? "all" })) {
            ForEach(library.catalog?.categories ?? []) { c in
                Label(c.title, systemImage: c.icon).tag(c.key)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 170)
    }

    private func cell(_ name: String) -> some View {
        let selected = name == selection
        return Button { pick(name) } label: {
            Image(systemName: name)
                .font(.system(size: 22))
                .foregroundStyle(Color(color))
                .frame(width: 52, height: 44)
                .background(selected ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private func pick(_ name: String) {
        selection = name
        library.noteUsed(name)
        done()
    }

    private func refresh() {
        results = library.catalog?.search(query, category: category) ?? []
    }
}
