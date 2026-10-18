import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @Bindable var store: DeviceStore
    @AppStorage(CLILocator.overrideKey) private var cliOverride = ""
    @AppStorage(CLILocator.transportKey) private var transport = ""
    @State private var loginError: String?
    @State private var loginStatus = SMAppService.mainApp.status

    private var loginEnabled: Bool {
        get { loginStatus == .enabled }
        nonmutating set {
            Task { @MainActor in
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    loginStatus = SMAppService.mainApp.status
                    loginError = nil
                } catch { loginError = error.localizedDescription }
            }
        }
    }

    var body: some View {
        Form {
            Section("Bluemock CLI") {
                HStack {
                    TextField("Path override (optional)", text: $cliOverride)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseCLI)
                }
                if let cli = store.cli {
                    Text("Detected: \(cli.executable.path) (\(cli.version))")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Not found").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Advanced") {
                TextField("Transport override (optional)", text: $transport)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to use the default Android netsim transport.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Login") {
                Toggle("Launch at login", isOn: Binding(get: { loginEnabled }, set: { loginEnabled = $0 }))
                Text("Status: \(String(describing: loginStatus))")
                    .font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 480)
        .task { await store.refresh() }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose bluemock executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { cliOverride = url.path }
    }
}
