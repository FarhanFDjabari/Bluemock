import SwiftUI
import AppKit

struct MenuPanel: View {
    @Bindable var store: DeviceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EnvironmentStrip(store: store)
            if store.cli == nil {
                installHint
            } else if store.devices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.devices) { device in
                            DeviceRow(device: device, process: store.processes[device.id],
                                      start: { store.start(device.id) },
                                      stop: { Task { await store.stop(device.id) } })
                            if device.id != store.devices.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }

            Divider()
            HStack {
                Button { } label: { Label("New device…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(true)
                    .help("Device editor arrives in a later version")
                Spacer()
                if let directory = store.deviceDirectory {
                    Button {
                        NSWorkspace.shared.open(directory)
                    } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Open devices folder")
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Quit Bluemock")
            }
        }
        .padding(14)
        .frame(width: 360)
        .task {
            await store.refresh()
            await store.startAutostartIfNeeded()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No devices yet").font(.headline)
            Text("Copy a preset to your devices folder to get started.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Menu {
                ForEach(store.presets) { preset in
                    Button("\(preset.name) — \(preset.id)") { Task { await store.copyPreset(preset.id) } }
                }
            } label: {
                Label("Add preset", systemImage: "plus")
            }
            .disabled(store.presets.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var installHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install the Bluemock CLI").font(.headline)
            Text("From a Bluemock checkout, run:").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(store.installCommand).font(.system(.caption, design: .monospaced))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.installCommand, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy install command")
            }
        }
        .padding(.vertical, 12)
    }
}
