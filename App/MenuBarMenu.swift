import AppKit
import LoopCore
import SwiftUI

struct MenuBarMenu: View {
    let engine: Engine
    @Environment(\.openWindow) private var openWindow
    @State private var loginItem = LoginItem.isEnabled

    var body: some View {
        Text(statusText)

        Divider()

        Picker("Profile", selection: Binding(get: { engine.profileID }, set: { engine.setProfile($0) })) {
            ForEach(engine.config.profiles) { Text($0.name).tag($0.id) }
        }
        Picker("Page", selection: Binding(get: { engine.pageIndex }, set: { engine.goToPage(.index($0)) })) {
            ForEach(Array(engine.profile.pages.enumerated()), id: \.element.id) { i, page in
                Text("\(i + 1). \(page.name)").tag(i)
            }
        }

        Divider()

        Button("Open Editor…") {
            openWindow(id: "editor")
            DockPolicy.windowOpened()
        }
        .keyboardShortcut("e")

        Toggle("Launch at Login", isOn: Binding(get: { loginItem }, set: { LoginItem.set($0); loginItem = LoginItem.isEnabled }))

        if !Permissions.accessibilityGranted {
            Button("Grant Accessibility Access (for keystrokes)…") { Permissions.requestAccessibility() }
        }

        Button(CLIInstaller.isInstalled ? "Reinstall Command-Line Tool" : "Install Command-Line Tool…") {
            showAlert(CLIInstaller.install())
        }

        if let error = engine.lastError {
            Divider()
            Button("⚠︎ \(error.prefix(80))") { showAlert(error) }
            Button("Clear Error") { engine.clearError() }
        }

        Divider()
        Button("Quit LoopDeLoop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch engine.status {
        case .searching: "No Loupedeck connected"
        case .recovering: "Reconnecting…"
        case .connected(let name, let fw): "\(name) · firmware \(fw)"
        }
    }

    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "LoopDeLoop"
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
