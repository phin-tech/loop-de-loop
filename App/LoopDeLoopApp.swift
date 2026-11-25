import AppKit
import LoopCore
import ServiceManagement
import SwiftUI

@main
struct LoopDeLoopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(engine: delegate.engine)
        } label: {
            Image(systemName: delegate.engine.isConnected ? "rectangle.grid.3x2.fill" : "rectangle.grid.3x2")
        }

        Window("LoopDeLoop", id: "editor") {
            EditorView(engine: delegate.engine)
                .onAppear { DockPolicy.windowOpened() }
                .onDisappear { DockPolicy.windowClosed() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands { ExchangeCommands(engine: delegate.engine) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Handle loopdeloop:// ourselves so SwiftUI doesn't open a window for every URL.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.start()
        LoginItem.enableOnFirstLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        let response = engine.handle(url: url)
        if !response.ok { NSLog("LoopDeLoop URL %@: %@", s, response.message) }
    }
}

/// Dock icon only while the editor is open.
@MainActor
enum DockPolicy {
    static func windowOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowClosed() {
        // Let the window finish closing, then drop back to menu-bar only.
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LoopDeLoop login item: %@", "\(error)")
        }
    }

    static func enableOnFirstLaunch() {
        let key = "didOfferLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}

@MainActor
enum CLIInstaller {
    static var bundledCLI: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/loopctl") }
    static var linkURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/loopctl") }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) == bundledCLI.path
    }

    /// Symlink ~/.local/bin/loopctl to the CLI inside the app bundle.
    static func install() -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledCLI.path) else { return "This build doesn't include loopctl (run `make install`)." }
        do {
            try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: linkURL)
            try fm.createSymbolicLink(at: linkURL, withDestinationURL: bundledCLI)
            return "Installed \(linkURL.path).\n\nBTT, Keyboard Maestro and Alfred run scripts with a minimal PATH, so call it by full path:\n\(linkURL.path)"
        } catch {
            return "Couldn't install: \(error.localizedDescription)"
        }
    }
}

@MainActor
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt (a C global Swift 6 flags)
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
