import SwiftUI
import AppKit

struct MenuPanel: View {
    @Bindable var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @State private var expandedDeviceID: String?

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
                                      stop: { Task { await store.stop(device.id) } },
                                      isExpanded: expandedDeviceID == device.id,
                                      toggleExpanded: {
                                          expandedDeviceID = expandedDeviceID == device.id ? nil : device.id
                                      },
                                      restartNeeded: store.restartRequired.contains(device.id),
                                      restart: { Task { await store.restart(device.id) } })
                            if expandedDeviceID == device.id {
                                DeviceDetail(process: store.processes[device.id])
                                    .transition(.opacity)
                            }
                            if device.id != store.devices.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 500)
            }

            Divider()
            HStack {
                Button { openEditor(.new) } label: { Label("New device…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Create a new device definition")
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
        .frame(minWidth: 360, maxWidth: 360, maxHeight: 600)
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

    private func openEditor(_ launch: EditorLaunch) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "editor", value: launch)
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
