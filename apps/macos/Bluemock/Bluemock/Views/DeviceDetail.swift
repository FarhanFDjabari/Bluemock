import SwiftUI

struct DeviceDetail: View {
    let process: DeviceProcess?

    var body: some View {
        Group {
            if let process, isStarting(process.status) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Starting device…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let process, process.isRunning, let ready = process.devicePayload?.objectValue {
                readyDetail(process, device: ready)
            } else if let process, process.isRunning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Starting device…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if case .error(let message)? = process?.status {
                Text(message).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Text("Start the device to send readings")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func readyDetail(_ process: DeviceProcess, device: [String: JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Actions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Disconnect central") { process.send(.drop()) }
                    .buttonStyle(.borderless)
                    .disabled(!isConnected(process.status))
                    .accessibilityLabel("Disconnect central from \(process.id)")
            }
            let actions = device["actions"]?.arrayValue ?? []
            if actions.isEmpty {
                Text("No actions defined").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    ActionForm(actionValue: action, process: process, session: process.session)
                }
            }
            StateView(values: process.stateValues)
            EventLog(process: process)
        }
    }

    private func isConnected(_ status: DeviceProcess.Status) -> Bool {
        if case .connected = status { return true }
        return false
    }

    private func isStarting(_ status: DeviceProcess.Status) -> Bool {
        if case .starting = status { return true }
        return false
    }
}
