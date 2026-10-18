import SwiftUI
import AppKit

struct MenuPanel: View {
    @Bindable var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @State private var expandedDeviceID: String?
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EnvironmentStrip(store: store)
            if store.cli == nil {
                installHint
            } else if store.devices.isEmpty {
                emptyState
            } else {
                // MenuBarExtra windows size to content, and maxHeight frames grow to fill the
                // offered height, so size the scroll area from the measured list height instead.
                ScrollView {
                    deviceList.background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ListHeightPreference.self, value: proxy.size.height)
                        }
                    }
                }
                .frame(height: min(listHeight, Self.maxListHeight))
                .onPreferenceChange(ListHeightPreference.self) { listHeight = $0 }
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
        .frame(width: 360)
        .task {
            await store.refresh()
            await store.startAutostartIfNeeded()
        }
    }

    private static let maxListHeight: CGFloat = 500

    private var deviceList: some View {
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

private struct ListHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
