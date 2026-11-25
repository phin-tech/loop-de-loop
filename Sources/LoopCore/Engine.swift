import AppKit
import Foundation
import LoupedeckKit
import Observation

/// Owns the device connection and the live state: which profile/page is showing,
/// runtime overrides from the CLI/URL scheme, and routing input to actions.
@MainActor
@Observable
public final class Engine: EngineActions {
    public enum Status: Equatable {
        case searching
        case connected(name: String, firmware: String)
        case recovering
    }

    public private(set) var config: Config
    public private(set) var profileID: UUID
    public private(set) var pageIndex = 0
    public private(set) var status: Status = .searching
    public private(set) var lastError: String?
    /// Controls currently held down ("key:3", "button:0", "knob:topLeft").
    public private(set) var pressed: Set<String> = []
    public private(set) var recoveries = 0

    public let images = ImageStore()
    @ObservationIgnored private let runner = ActionRunner()
    @ObservationIgnored private var device: LoupedeckDevice?
    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored private var started = false

    // Runtime overrides, keyed by page ID. Not saved unless --persist is used.
    @ObservationIgnored private var keyOverrides: [UUID: [Int: Appearance]] = [:]
    @ObservationIgnored private var labelOverrides: [UUID: [Knob: String]] = [:]
    @ObservationIgnored private var buttonOverrides: [UUID: [Int: RGB]] = [:]

    // Press/hold tracking.
    @ObservationIgnored private var pressBindings: [String: Bindings] = [:]
    @ObservationIgnored private var holdTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var held: Set<String> = []
    @ObservationIgnored private var touchKeys: [UInt8: Int] = [:]

    // Coalesced drawing.
    @ObservationIgnored private var needsFullRedraw = false
    @ObservationIgnored private var dirtyKeys: Set<Int> = []
    @ObservationIgnored private var drawing = false

    public init(config: Config? = nil) {
        let loaded: Config
        var loadError: String?
        if let config {
            loaded = config
        } else {
            do { loaded = try ConfigStore.load() } catch {
                loaded = .starter()
                loadError = "Couldn't read config.json (\(error)); using the starter layout."
            }
        }
        self.config = loaded
        self.profileID = loaded.defaultProfileID
        self.lastError = loadError
        runner.engine = self
        runner.onError = { [weak self] message in self?.report(message) }
    }

    // MARK: - Lifecycle

    /// Start the connection loop, the control socket and app-based profile switching.
    public func start() {
        guard !started else { return }
        started = true
        let server = ControlServer { [weak self] request in
            await MainActor.run { self?.handle(request) } ?? .error("app is shutting down")
        }
        do { try server.start() } catch { report("Control socket: \(error)") }
        self.server = server

        Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.device == nil { await self.connect() }
                try? await Task.sleep(for: .seconds(2))
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontmostAppChanged(bundleID) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect(reason: "wake from sleep") }
        }
    }

    private func connect() async {
        guard let found = Discovery.devices().first(where: { $0.model != nil }) else { return }
        do {
            let d = try await LoupedeckDevice.connect(path: found.path, model: found.model ?? .live)
            let firmware = (try? await d.firmwareVersion()) ?? "?"
            device = d
            status = .connected(name: d.model.name, firmware: firmware)
            try? await d.setBrightness(config.settings.brightness)
            applyButtonColors()
            requestRedraw()
            Task { [weak self] in
                for await event in d.events { self?.handle(event) }
                self?.deviceEnded(d)
            }
        } catch {
            report("Connect: \(error)")
        }
    }

    private func deviceEnded(_ d: LoupedeckDevice) {
        guard device === d else { return }
        device = nil
        status = .searching
        releaseAll()
    }

    /// Drop the connection and reconnect right away (the firmware un-wedges on reopen).
    private func reconnect(reason: String) {
        guard let d = device else { return }
        recoveries += 1
        status = .recovering
        device = nil
        d.close()
        releaseAll()
        Task { await connect() }
    }

    // MARK: - State

    public var profile: Profile { config.profile(id: profileID) ?? config.profiles[0] }
    public var page: Page {
        let pages = profile.pages
        return pages[min(pageIndex, pages.count - 1)]
    }
    public var model: LoupedeckModel { device?.model ?? .live }

    public func effectiveAppearance(key i: Int) -> Appearance {
        page.key(i).appearance.merged(with: keyOverrides[page.id]?[i])
    }

    /// Replace the whole config (from the editor) and redraw.
    public func update(_ newConfig: Config, save: Bool = true) {
        config = newConfig
        if config.profile(id: profileID) == nil { profileID = config.defaultProfileID }
        pageIndex = min(pageIndex, profile.pages.count - 1)
        if save { persist() }
        applyButtonColors()
        requestRedraw()
    }

    private func persist() {
        do { try ConfigStore.save(config) } catch { report("Save failed: \(error)") }
    }

    private func report(_ message: String) {
        lastError = "\(Date().formatted(date: .omitted, time: .standard)) \(message)"
        NSLog("LoopDeLoop: %@", message)
    }

    // MARK: - EngineActions

    public func goToPage(_ target: PageTarget) {
        let pages = profile.pages
        let index: Int? = switch target {
        case .next: (pageIndex + 1) % pages.count
        case .previous: (pageIndex - 1 + pages.count) % pages.count
        case .index(let i): pages.indices.contains(i) ? i : nil
        case .named(let n): pages.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        }
        guard let index else { return report("No page \(target)") }
        guard index != pageIndex else { return }
        pageIndex = index
        applyButtonColors()
        requestRedraw()
    }

    public func switchProfile(named name: String) {
        guard let p = config.profile(named: name) else { return report("No profile named \(name)") }
        setProfile(p.id)
    }

    public func setProfile(_ id: UUID) {
        guard id != profileID else { return }
        profileID = id
        pageIndex = 0
        applyButtonColors()
        requestRedraw()
    }

    private func frontmostAppChanged(_ bundleID: String?) {
        guard config.settings.autoSwitchProfiles, let bundleID else { return }
        if let p = config.profiles.first(where: { $0.appBundleIDs.contains(bundleID) }) {
            setProfile(p.id)
        } else if config.profiles.contains(where: { !$0.appBundleIDs.isEmpty }) {
            // Leaving an app with its own profile returns to the default one.
            setProfile(config.defaultProfileID)
        }
    }

    public func changeBrightness(_ change: BrightnessChange) {
        let current = config.settings.brightness
        let value = switch change {
        case .set(let v): v
        case .adjust(let d): current + d
        }
        config.settings.brightness = max(0, min(1, value))
        persist()
        if let d = device { Task { try? await d.setBrightness(config.settings.brightness) } }
    }

    public func vibrate(_ pattern: Haptic) {
        if let d = device { Task { try? await d.vibrate(pattern) } }
    }

    public var bttSharedSecret: String? { config.settings.bttSharedSecret }

    // MARK: - Drawing

    /// Redraw everything (nil) or just one key. Bursts are coalesced, so a script
    /// updating a key 100 times a second only draws the latest state.
    public func requestRedraw(key: Int? = nil) {
        if let key { dirtyKeys.insert(key) } else { needsFullRedraw = true }
        guard !drawing else { return }
        drawing = true
        Task { await drainDraws() }
    }

    private func drainDraws() async {
        defer { drawing = false }
        while let d = device, needsFullRedraw || !dirtyKeys.isEmpty {
            let full = needsFullRedraw
            let keys = dirtyKeys
            needsFullRedraw = false
            dirtyKeys = []
            do {
                if full {
                    try await drawPage(on: d)
                } else {
                    for k in keys.sorted() {
                        let r = d.model.rect(forKey: k)
                        let px = Renderer.key(effectiveAppearance(key: k), size: d.model.keySize, images: images)
                        try await d.drawPixels(x: r.x, y: r.y, width: r.width, height: r.height, rgb565: px, refresh: false)
                    }
                    try await d.refresh()
                }
            } catch {
                // A missing ack means the firmware wedged: reconnect, and redraw everything.
                report("Device stopped responding (\(error)); reconnecting")
                needsFullRedraw = true
                reconnect(reason: "draw timeout")
                return
            }
        }
    }

    private func drawPage(on d: LoupedeckDevice) async throws {
        var page = self.page
        for (knob, label) in labelOverrides[page.id] ?? [:] { page.knobs[knob, default: KnobConfig()].label = label }
        let px = Renderer.page(page, overrides: keyOverrides[page.id] ?? [:], model: d.model, images: images)
        try await d.drawPixels(x: 0, y: 0, width: d.model.screenWidth, height: d.model.screenHeight, rgb565: px)
    }

    private func applyButtonColors() {
        guard let d = device else { return }
        let page = self.page
        let overrides = buttonOverrides[page.id] ?? [:]
        Task {
            for i in 0..<d.model.roundButtons {
                let c = overrides[i] ?? page.button(i).color ?? .black
                try? await d.setButtonColor(i, red: c.red, green: c.green, blue: c.blue)
            }
        }
    }

    // MARK: - Input

    private func handle(_ event: LoupedeckEvent) {
        switch event {
        case .pressed(let control):
            let (id, bindings) = binding(for: control)
            down(id, bindings)
        case .released(let control):
            up(id(for: control))
        case .rotated(let knob, let delta):
            let k = page.knob(knob)
            let actions = delta > 0 ? k.right : k.left
            // One run per detent, each with {delta} = ±1, so repeated calls add up correctly.
            let ctx = context("knob:\(knob.rawValue)", delta: delta.signum())
            for _ in 0..<abs(delta) { runner.run(actions, context: ctx) }
        case .touchBegan(let touch):
            guard case .key(let i) = touch.target else { return }
            touchKeys[touch.id] = i
            down("key:\(i)", page.key(i).actions)
        case .touchMoved:
            break
        case .touchEnded(let touch):
            guard let i = touchKeys.removeValue(forKey: touch.id) else { return }
            up("key:\(i)")
        case .disconnected:
            break
        }
    }

    private func id(for control: Control) -> String {
        switch control {
        case .knob(let k): "knob:\(k.rawValue)"
        case .button(let n): "button:\(n)"
        }
    }

    private func binding(for control: Control) -> (String, Bindings) {
        switch control {
        case .knob(let k): (id(for: control), page.knob(k).actions)
        case .button(let n): (id(for: control), page.button(n).actions)
        }
    }

    private func context(_ control: String, delta: Int? = nil) -> ActionContext {
        ActionContext(control: control, delta: delta, page: page.name, profile: profile.name)
    }

    /// Press: fire immediately, unless the control has hold actions — then wait to see
    /// whether it's a tap (press actions on release) or a hold (hold actions after the delay).
    private func down(_ id: String, _ bindings: Bindings) {
        pressed.insert(id)
        pressBindings[id] = bindings
        if config.settings.hapticOnPress { vibrate(.short) }
        if bindings.hold.isEmpty {
            runner.run(bindings.press, context: context(id))
        } else {
            let delay = config.settings.holdDelay
            holdTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.pressed.contains(id) else { return }
                self.held.insert(id)
                self.runner.run(bindings.hold, context: self.context(id))
            }
        }
    }

    private func up(_ id: String) {
        pressed.remove(id)
        holdTasks.removeValue(forKey: id)?.cancel()
        guard let bindings = pressBindings.removeValue(forKey: id) else { return }
        if !bindings.hold.isEmpty, !held.contains(id) {
            runner.run(bindings.press, context: context(id))
        }
        held.remove(id)
        runner.run(bindings.release, context: context(id))
    }

    private func releaseAll() {
        for t in holdTasks.values { t.cancel() }
        holdTasks = [:]
        pressBindings = [:]
        held = []
        pressed = []
        touchKeys = [:]
    }

    // MARK: - Control commands (CLI / URL scheme)

    public func handle(_ req: ControlRequest) -> ControlResponse {
        let a = req.args
        func int(_ s: String?) -> Int? { s.flatMap { Int($0) } }
        func targetPage() -> (Int, Page)? {
            guard let p = a["page"] else { return (pageIndex, page) }
            let pages = profile.pages
            let i: Int? = switch PageTarget(argument: p) {
            case .index(let n): pages.indices.contains(n) ? n : nil
            case .named(let n): pages.firstIndex { $0.name.caseInsensitiveCompare(n) == .orderedSame }
            case .next: (pageIndex + 1) % pages.count
            case .previous: (pageIndex - 1 + pages.count) % pages.count
            }
            return i.map { ($0, pages[$0]) }
        }

        switch req.command {
        case "status":
            let connection = switch status {
            case .searching: "no device"
            case .recovering: "reconnecting"
            case .connected(let name, let fw): "\(name), firmware \(fw)"
            }
            return .ok("""
                device: \(connection)
                profile: \(profile.name)
                page: \(pageIndex + 1)/\(profile.pages.count) \(page.name)
                brightness: \(Int(config.settings.brightness * 100))%
                recoveries: \(recoveries)\(lastError.map { "\nlast error: \($0)" } ?? "")
                """)

        case "pages":
            return .ok(profile.pages.enumerated().map { "\($0 + 1)\($0 == pageIndex ? "*" : " ") \($1.name)" }.joined(separator: "\n"))

        case "profiles":
            return .ok(config.profiles.map { "\($0.id == profileID ? "*" : " ") \($0.name)" }.joined(separator: "\n"))

        case "page":
            guard let t = req.positional(0) else { return .error("usage: page <next|prev|number|name>") }
            goToPage(PageTarget(argument: t))
            return .ok("page \(pageIndex + 1): \(page.name)")

        case "profile":
            guard let n = req.positional(0) else { return .error("usage: profile <name>") }
            guard let p = config.profile(named: n) else { return .error("no profile named \(n)") }
            setProfile(p.id)
            return .ok("profile: \(p.name)")

        case "set-key":
            guard let k = int(req.positional(0)), (0..<model.keyCount).contains(k) else {
                return .error("usage: set-key <0-\(model.keyCount - 1)> [--title T] [--bg RRGGBB] [--title-color RRGGBB] [--symbol NAME] [--symbol-color RRGGBB] [--image PATH] [--font-size N] [--page P] [--persist]")
            }
            guard let (pi, pg) = targetPage() else { return .error("no such page") }
            var o = Appearance()
            o.title = a["title"]
            if let s = a["bg"] { guard let c = RGB(hex: s) else { return .error("bad color \(s)") }; o.background = c }
            if let s = a["title-color"] { guard let c = RGB(hex: s) else { return .error("bad color \(s)") }; o.titleColor = c }
            if let s = a["symbol-color"] { guard let c = RGB(hex: s) else { return .error("bad color \(s)") }; o.symbolColor = c }
            o.symbol = a["symbol"]
            if let s = a["font-size"] { o.fontSize = Double(s) }
            if let path = a["image"] {
                do { o.image = try images.importImage(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) } catch {
                    return .error("image: \(error.localizedDescription)")
                }
            }
            if a["persist"] == "true" {
                var c = config
                c.profiles[profileIndex].pages[pi].keys[String(k), default: KeyConfig()].appearance =
                    pg.key(k).appearance.merged(with: o)
                update(c)
            } else {
                keyOverrides[pg.id, default: [:]][k] = (keyOverrides[pg.id]?[k] ?? Appearance()).merged(with: o)
                if pi == pageIndex { requestRedraw(key: k) }
            }
            return .ok()

        case "clear-key":
            guard let (pi, pg) = targetPage() else { return .error("no such page") }
            if req.positional(0) == "all" {
                keyOverrides[pg.id] = nil
                if pi == pageIndex { requestRedraw() }
            } else if let k = int(req.positional(0)) {
                keyOverrides[pg.id]?[k] = nil
                if pi == pageIndex { requestRedraw(key: k) }
            } else {
                return .error("usage: clear-key <n|all> [--page P]")
            }
            return .ok()

        case "label":
            guard let name = req.positional(0), let knob = Knob(argument: name), let text = req.positional(1) ?? a["text"] else {
                return .error("usage: label <tl|cl|bl|tr|cr|br> <text>")
            }
            guard let (pi, pg) = targetPage() else { return .error("no such page") }
            labelOverrides[pg.id, default: [:]][knob] = text
            if pi == pageIndex { requestRedraw() }
            return .ok()

        case "button-color":
            guard let n = int(req.positional(0)), (0..<model.roundButtons).contains(n),
                  let c = req.positional(1).flatMap(RGB.init(hex:)) else {
                return .error("usage: button-color <0-\(model.roundButtons - 1)> <RRGGBB>")
            }
            guard let (pi, pg) = targetPage() else { return .error("no such page") }
            buttonOverrides[pg.id, default: [:]][n] = c
            if pi == pageIndex { applyButtonColors() }
            return .ok()

        case "brightness":
            guard let s = req.positional(0), let v = Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "+%"))) else {
                return .error("usage: brightness <0-100 | +10 | -10>")
            }
            changeBrightness(s.hasPrefix("+") || s.hasPrefix("-") ? .adjust(v / 100) : .set(v / 100))
            return .ok("brightness: \(Int(config.settings.brightness * 100))%")

        case "vibrate":
            let pattern = req.positional(0).flatMap { name in Haptic.allCases.first { "\($0)".lowercased() == name.lowercased() } } ?? .short
            vibrate(pattern)
            return .ok()

        case "press":
            // Simulate a press+release: key:3, button:2, knob:tl
            guard let spec = req.positional(0) else { return .error("usage: press <key:N|button:N|knob:tl…>") }
            let parts = spec.split(separator: ":").map(String.init)
            guard parts.count == 2 else { return .error("usage: press <key:N|button:N|knob:tl…>") }
            switch parts[0] {
            case "key": guard let n = Int(parts[1]) else { return .error("bad key") }; down("key:\(n)", page.key(n).actions); up("key:\(n)")
            case "button": guard let n = Int(parts[1]) else { return .error("bad button") }; handle(.pressed(.button(n))); handle(.released(.button(n)))
            case "knob": guard let k = Knob(argument: parts[1]) else { return .error("bad knob") }; handle(.pressed(.knob(k))); handle(.released(.knob(k)))
            default: return .error("unknown control \(parts[0])")
            }
            return .ok()

        case "turn":
            guard let name = req.positional(0), let knob = Knob(argument: name), let d = int(req.positional(1)) else {
                return .error("usage: turn <knob> <delta>")
            }
            handle(.rotated(knob, delta: d))
            return .ok()

        case "save":
            persist()
            return .ok("saved \(Paths.configFile.path)")

        case "reload":
            do {
                update(try ConfigStore.load(), save: false)
                return .ok("reloaded \(Paths.configFile.path)")
            } catch {
                return .error("reload failed: \(error)")
            }

        default:
            return .error("unknown command \(req.command)")
        }
    }

    public var profileIndex: Int { config.profiles.firstIndex { $0.id == profileID } ?? 0 }

    // MARK: - Editing helpers (used by the editor UI)

    /// Mutate the config, save it and redraw.
    public func edit(_ body: (inout Config) -> Void) {
        var c = config
        body(&c)
        update(c)
    }

    /// Mutate the page currently showing.
    public func editPage(_ body: (inout Page) -> Void) {
        let (pi, gi) = (profileIndex, min(pageIndex, profile.pages.count - 1))
        edit { body(&$0.profiles[pi].pages[gi]) }
    }

    public func editProfile(_ body: (inout Profile) -> Void) {
        let pi = profileIndex
        edit { body(&$0.profiles[pi]) }
    }

    public var isConnected: Bool { if case .connected = status { true } else { false } }

    public func clearError() { lastError = nil }

    /// Handle a loopdeloop:// URL.
    @discardableResult
    public func handle(url: URL) -> ControlResponse {
        guard let request = ControlRequest(url: url) else { return .error("not a loopdeloop:// URL") }
        return handle(request)
    }
}

extension Knob {
    /// "tl", "topLeft", "top-left", …
    public init?(argument s: String) {
        let k = s.lowercased().replacingOccurrences(of: "-", with: "")
        switch k {
        case "tl", "topleft": self = .topLeft
        case "cl", "centerleft", "ml", "middleleft": self = .centerLeft
        case "bl", "bottomleft": self = .bottomLeft
        case "tr", "topright": self = .topRight
        case "cr", "centerright", "mr", "middleright": self = .centerRight
        case "br", "bottomright": self = .bottomRight
        default: return nil
        }
    }
}
