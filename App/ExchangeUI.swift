import AppKit
import LoopCore
import SwiftUI
import UniformTypeIdentifiers

/// Save/open panels for export, import and restore.
@MainActor
enum ExchangeUI {
    static func exportProfile(_ engine: Engine) {
        let p = engine.profile
        guard let url = savePanel(name: "\(p.name).\(ExportFile.fileExtension)", title: "Export “\(p.name)”") else { return }
        run { try engine.export(to: url, profileIDs: [p.id]) }
    }

    static func exportAll(_ engine: Engine) {
        let stamp = Date().formatted(.iso8601.year().month().day())
        guard let url = savePanel(name: "LoopDeLoop backup \(stamp).\(ExportFile.fileExtension)",
                                  title: "Export Everything (profiles and settings)") else { return }
        run { try engine.export(to: url, fullBackup: true) }
    }

    static func importProfiles(_ engine: Engine) {
        guard let url = openPanel(title: "Import Profiles") else { return }
        run {
            let file = try ExportFile.decode(Data(contentsOf: url))
            let names = try engine.importProfiles(from: file)
            if let first = engine.config.profile(named: names.first ?? "") { engine.setProfile(first.id) }
            info("Imported \(names.count == 1 ? "profile" : "profiles") \(names.map { "“\($0)”" }.joined(separator: ", ")).")
        }
    }

    static func restore(_ engine: Engine) {
        guard let url = openPanel(title: "Restore from Backup") else { return }
        run {
            let file = try ExportFile.decode(Data(contentsOf: url))
            let alert = NSAlert()
            alert.messageText = "Replace all profiles\(file.isFullBackup ? " and settings" : "")?"
            alert.informativeText = "Your current setup will be replaced by the \(file.profiles.count) profile(s) in “\(url.lastPathComponent)”. A backup of the current setup is saved first."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let backup = try engine.restore(from: file)
            info("Restored. Your previous setup was saved to:\n\(backup.path)")
        }
    }

    static func showBackups() {
        let dir = Paths.supportDirectory.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Helpers

    private static func savePanel(name: String, title: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func openPanel(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func run(_ body: () throws -> Void) {
        do { try body() } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't complete that"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    private static func info(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "LoopDeLoop"
        alert.informativeText = text
        alert.runModal()
    }
}

/// File menu entries (shown while the editor is open and the app is in the foreground).
struct ExchangeCommands: Commands {
    let engine: Engine
    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Import Profiles…") { ExchangeUI.importProfiles(engine) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Export Current Profile…") { ExchangeUI.exportProfile(engine) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Export Everything…") { ExchangeUI.exportAll(engine) }
            Divider()
            Button("Restore from Backup…") { ExchangeUI.restore(engine) }
            Button("Show Backups Folder") { ExchangeUI.showBackups() }
        }
    }
}
