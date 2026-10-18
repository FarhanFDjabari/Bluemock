import SwiftUI
import AppKit

struct DeviceRow: View {
    let device: DeviceSummary
    let process: DeviceProcess?
    let start: () -> Void
    let stop: () -> Void
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let restartNeeded: Bool
    let restart: () -> Void
    @Environment(\.openWindow) private var openWindow

    private var status: DeviceProcess.Status { process?.status ?? .stopped }
    private var tint: Color {
        switch status {
        case .stopped: .gray
        case .starting: .orange
        case .advertising: .blue
        case .connected: .green
        case .error: .red
        }
    }
    private var statusText: String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .advertising: "Advertising"
        case .connected(let peer): "Connected to \(peer)"
        case .error(let message): message
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleExpanded) {
                HStack(spacing: 10) {
                    Circle().fill(device.valid ? tint : .red).frame(width: 9, height: 9)
                        .accessibilityLabel("Device status")
                        .accessibilityValue(device.valid ? statusText : "Invalid definition")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name.isEmpty ? device.id : device.name).font(.body)
                        Text(device.id).font(.caption).foregroundStyle(.secondary)
                        if !device.valid {
                            Text(device.error ?? "Invalid device definition")
                                .font(.caption).foregroundStyle(.red).lineLimit(1)
                                .help(device.error ?? "Invalid device definition")
                        } else if case .error(let message) = status {
                            Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
                        }
                    }
                    Spacer(minLength: 2)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(device.name) details")
            .accessibilityValue(device.valid ? statusText : "Invalid definition")
            Spacer()
            Button {
                if process?.isRunning == true { stop() } else { start() }
            } label: {
                Image(systemName: process?.isRunning == true ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!device.valid)
            .accessibilityLabel(process?.isRunning == true ? "Stop \(device.name)" : "Start \(device.name)")
            if restartNeeded {
                Button("Restart to apply", action: restart)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Restart \(device.name) to apply saved changes")
            }
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Edit…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "editor", value: EditorLaunch.edit(path: device.path))
            }
            Button("Reveal in Finder") {
                NSApp.activate(ignoringOtherApps: true)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: device.path)])
            }
        }
    }
}
