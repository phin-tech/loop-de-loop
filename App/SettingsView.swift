import AppKit
import LoopCore
import SwiftUI

struct SettingsView: View {
    let engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var loginItem = LoginItem.isEnabled
    @State private var cliMessage: String?

    private var settings: Binding<LoopCore.Settings> {
        Binding(get: { engine.config.settings }, set: { v in engine.edit { $0.settings = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Device") {
                    HStack {
                        Text("Brightness")
                        Slider(value: Binding(get: { engine.config.settings.brightness },
                                              set: { engine.changeBrightness(.set($0)) }), in: 0...1, step: 0.1)
                        Text("\(Int(engine.config.settings.brightness * 100))%").monospacedDigit().frame(width: 40)
                    }
                    HStack {
                        Text("Hold after")
                        Slider(value: settings.holdDelay, in: 0.2...1.5, step: 0.05)
                        Text(String(format: "%.2f s", settings.wrappedValue.holdDelay)).monospacedDigit().frame(width: 50)
                    }
                    Toggle("Vibrate on every press", isOn: settings.hapticOnPress)
                    Toggle("Switch profiles to match the frontmost app", isOn: settings.autoSwitchProfiles)
                }

                Section("BetterTouchTool") {
                    TextField("Shared secret (only if set in BTT → Advanced → Scripting)",
                              text: optionalText(settings.bttSharedSecret))
                }

                Section("System") {
                    Toggle("Launch at login", isOn: Binding(get: { loginItem }, set: { LoginItem.set($0); loginItem = LoginItem.isEnabled }))
                    HStack {
                        Text("Accessibility (for keyboard shortcuts)")
                        Spacer()
                        if Permissions.accessibilityGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Grant…") { Permissions.requestAccessibility() }
                        }
                    }
                    HStack {
                        Text("Command-line tool")
                        Spacer()
                        Text(CLIInstaller.isInstalled ? CLIInstaller.linkURL.path : "not installed")
                            .foregroundStyle(.secondary).font(.caption)
                        Button(CLIInstaller.isInstalled ? "Reinstall" : "Install") { cliMessage = CLIInstaller.install() }
                    }
                    HStack {
                        Text("Config file")
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile]) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .alert("Command-line tool", isPresented: Binding(get: { cliMessage != nil }, set: { if !$0 { cliMessage = nil } })) {
            Button("OK") {}
        } message: { Text(cliMessage ?? "") }
    }
}

/// Bundle IDs that switch to the current profile when their app comes to the front.
struct ProfileAppsSheet: View {
    let engine: Engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use “\(engine.profile.name)” when these apps are frontmost").font(.headline)
            List {
                ForEach(engine.profile.appBundleIDs, id: \.self) { id in
                    HStack {
                        Text(appName(id) ?? id)
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { engine.editProfile { $0.appBundleIDs.removeAll { $0 == id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Menu("Add Running App") {
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            guard let id = app.bundleIdentifier else { return }
                            engine.editProfile { if !$0.appBundleIDs.contains(id) { $0.appBundleIDs.append(id) } }
                        }
                    }
                }
                .fixedSize()
                Button("Add App…") { chooseApp() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Other apps fall back to the default profile.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 480, height: 360)
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(_ id: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        engine.editProfile { if !$0.appBundleIDs.contains(id) { $0.appBundleIDs.append(id) } }
    }
}
