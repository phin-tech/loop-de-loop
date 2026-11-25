import AppKit
import CoreGraphics
import Foundation
import LoupedeckKit

/// Values substituted into action strings: {delta}, {control}, {page}, {profile}.
public struct ActionContext: Sendable {
    public var control: String
    public var delta: Int?
    public var page: String
    public var profile: String

    public init(control: String, delta: Int? = nil, page: String = "", profile: String = "") {
        self.control = control
        self.delta = delta
        self.page = page
        self.profile = profile
    }

    func fill(_ s: String) -> String {
        s.replacingOccurrences(of: "{delta}", with: delta.map(String.init) ?? "")
            .replacingOccurrences(of: "{control}", with: control)
            .replacingOccurrences(of: "{page}", with: page)
            .replacingOccurrences(of: "{profile}", with: profile)
    }

    func fill(_ s: String?) -> String? { s.map(fill) }
}

/// Things only the engine can do (paging, brightness, haptics).
@MainActor
public protocol EngineActions: AnyObject {
    func goToPage(_ target: PageTarget)
    func switchProfile(named: String)
    func changeBrightness(_ change: BrightnessChange)
    func vibrate(_ pattern: Haptic)
    var bttSharedSecret: String? { get }
}

public struct ActionError: Error, CustomStringConvertible {
    public let description: String
}

/// Runs actions in order. Anything that can block (scripts, shell, other apps) runs off
/// the main actor with a timeout, so a slow target can never stall device input.
@MainActor
public final class ActionRunner {
    public weak var engine: EngineActions?
    /// Called with a human-readable message when an action fails.
    public var onError: ((String) -> Void)?
    nonisolated public static let scriptTimeout: TimeInterval = 10

    public init() {}

    public func run(_ actions: [Action], context: ActionContext) {
        guard !actions.isEmpty else { return }
        Task { @MainActor in
            for action in actions {
                do {
                    try await perform(action, context)
                } catch {
                    onError?("\(action.summary): \(error)")
                }
            }
        }
    }

    func perform(_ action: Action, _ ctx: ActionContext) async throws {
        switch action {
        case .keystroke(let k):
            try Keyboard.post(k)
        case .typeText(let text):
            try Keyboard.type(ctx.fill(text))
        case .openApp(let path):
            let url = URL(fileURLWithPath: ctx.fill(path))
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .openURL(let s):
            guard let url = URL(string: ctx.fill(s)) else { throw ActionError(description: "Invalid URL") }
            NSWorkspace.shared.open(url)
        case .shell(let command):
            try await Subprocess.run("/bin/zsh", ["-lc", ctx.fill(command)], env: env(ctx))
        case .appleScript(let source):
            try await Subprocess.osascript(ctx.fill(source))
        case .shortcut(let name, let input):
            var args = ["run", ctx.fill(name)]
            if let input = ctx.fill(input) {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("loopdeloop-\(UUID()).txt")
                try input.write(to: file, atomically: true, encoding: .utf8)
                args += ["--input-path", file.path]
            }
            try await Subprocess.run("/usr/bin/shortcuts", args)
        case .bttNamedTrigger(let name, let value):
            try await Integrations.btt(trigger: ctx.fill(name), value: ctx.fill(value) ?? ctx.delta.map(String.init),
                                       secret: engine?.bttSharedSecret)
        case .keyboardMaestro(let macro, let parameter):
            try await Integrations.keyboardMaestro(macro: ctx.fill(macro), parameter: ctx.fill(parameter))
        case .alfredTrigger(let trigger, let workflow, let argument):
            try await Integrations.alfred(trigger: ctx.fill(trigger), workflow: ctx.fill(workflow), argument: ctx.fill(argument))
        case .media(let key):
            try Keyboard.postMediaKey(key)
        case .page(let target):
            engine?.goToPage(target)
        case .profile(let name):
            engine?.switchProfile(named: ctx.fill(name))
        case .brightness(let change):
            engine?.changeBrightness(change)
        case .vibrate(let pattern):
            engine?.vibrate(pattern)
        case .delay(let seconds):
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    private func env(_ ctx: ActionContext) -> [String: String] {
        var e = ["LOOPDELOOP_CONTROL": ctx.control, "LOOPDELOOP_PAGE": ctx.page, "LOOPDELOOP_PROFILE": ctx.profile]
        if let d = ctx.delta { e["LOOPDELOOP_DELTA"] = String(d) }
        return e
    }
}

// MARK: - BTT / Keyboard Maestro / Alfred

public enum Integrations {
    public static let bttBundleID = "com.hegenberg.BetterTouchTool"
    public static let kmEngineBundleID = "com.stairways.keyboardmaestro.engine"
    public static let alfredBundleID = "com.runningwithcrayons.Alfred"

    /// Fires a BTT named trigger without waiting for its actions to finish.
    /// If `value` is set, BTT variable `loopdeloop_value` is set first.
    static func btt(trigger: String, value: String?, secret: String?) async throws {
        let secretClause = secret.map { " shared_secret \(AppleScript.quote($0))" } ?? ""
        var script = "tell application id \"\(bttBundleID)\"\n"
        if let value {
            script += "set_string_variable \"loopdeloop_value\" to \(AppleScript.quote(value))\(secretClause)\n"
        }
        script += "trigger_named_async_without_response \(AppleScript.quote(trigger))\(secretClause)\nend tell"
        try await Subprocess.osascript(script)
    }

    /// Runs a Keyboard Maestro macro by name or UID. `parameter` becomes %TriggerValue%.
    static func keyboardMaestro(macro: String, parameter: String?) async throws {
        let param = parameter.map { " with parameter \(AppleScript.quote($0))" } ?? ""
        try await Subprocess.osascript(
            "tell application id \"\(kmEngineBundleID)\" to do script \(AppleScript.quote(macro))\(param)")
    }

    /// Calls an Alfred External Trigger (works with Alfred 5 and 6, which share a bundle ID).
    static func alfred(trigger: String, workflow: String, argument: String?) async throws {
        let arg = argument.map { " with argument \(AppleScript.quote($0))" } ?? ""
        do {
            try await Subprocess.osascript(
                "tell application id \"\(alfredBundleID)\" to run trigger \(AppleScript.quote(trigger)) in workflow \(AppleScript.quote(workflow))\(arg)")
        } catch let error as ActionError {
            // Alfred's documented error codes for run trigger.
            let hints = ["(-2)": "workflow not found", "(-3)": "trigger not found", "(-4)": "workflow is disabled"]
            if let hint = hints.first(where: { error.description.contains($0.key) })?.value {
                throw ActionError(description: "Alfred: \(hint)")
            }
            throw error
        }
    }

    /// Keyboard Maestro macros as (group, name, uid) for pickers. Empty if the Engine isn't running.
    public static func keyboardMaestroMacros() async -> [(group: String, name: String, uid: String)] {
        guard let out = try? await Subprocess.osascript(
            "tell application id \"\(kmEngineBundleID)\" to getmacros with asstring"),
            let data = out.data(using: .utf8),
            let groups = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return groups.flatMap { group -> [(String, String, String)] in
            let groupName = group["name"] as? String ?? ""
            return (group["macros"] as? [[String: Any]] ?? []).compactMap { m in
                guard let name = m["name"] as? String, let uid = m["uid"] as? String else { return nil }
                return (groupName, name, uid)
            }
        }
    }
}

enum AppleScript {
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Subprocesses

enum Subprocess {
    /// Runs a process off the main thread; throws on non-zero exit or timeout. Returns stdout.
    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String] = [:],
                    timeout: TimeInterval = ActionRunner.scriptTimeout) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { return cont.resume(throwing: error) }
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                if p.terminationReason == .uncaughtSignal {
                    return cont.resume(throwing: ActionError(description: "timed out after \(Int(timeout))s"))
                }
                guard p.terminationStatus == 0 else {
                    let msg = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    return cont.resume(throwing: ActionError(description: msg.isEmpty ? "exit \(p.terminationStatus)" : msg))
                }
                cont.resume(returning: String(decoding: stdout, as: UTF8.self))
            }
        }
    }

    @discardableResult
    static func osascript(_ source: String) async throws -> String {
        try await run("/usr/bin/osascript", ["-e", source])
    }
}

// MARK: - Keyboard

enum Keyboard {
    static func flags(_ mods: [KeyStroke.Modifier]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in mods {
            switch m {
            case .command: f.insert(.maskCommand)
            case .shift: f.insert(.maskShift)
            case .option: f.insert(.maskAlternate)
            case .control: f.insert(.maskControl)
            case .function: f.insert(.maskSecondaryFn)
            }
        }
        return f
    }

    static func post(_ k: KeyStroke) throws {
        guard let code = k.keyCode else { throw ActionError(description: "Unknown key \(k.key)") }
        try requireAccessibility()
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags(k.modifiers)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Posting events silently does nothing without Accessibility, so fail loudly instead.
    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ActionError(description: "needs Accessibility permission (System Settings → Privacy & Security → Accessibility)")
        }
    }

    static func type(_ text: String) throws {
        try requireAccessibility()
        let src = CGEventSource(stateID: .hidSystemState)
        for chunk in text.chunked(20) {
            let utf16 = Array(chunk.utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                e?.post(tap: .cghidEventTap)
            }
        }
    }

    static func postMediaKey(_ key: MediaKey) throws {
        try requireAccessibility()
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key.nxKeyType << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

private extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = [], cur = ""
        for ch in self {
            cur.append(ch)
            if cur.count == n { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
