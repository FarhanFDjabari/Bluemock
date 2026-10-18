import SwiftUI

struct EditorStartSheet: View {
    let presets: [CLIRunner.Preset]
    let devices: [DeviceSummary]
    let blank: () -> Void
    let preset: (String) -> Void
    let duplicate: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Blank") {
                    Button { blank() } label: { Label("New device definition", systemImage: "doc.badge.plus") }
                }
                Section("From preset") {
                    ForEach(presets) { item in
                        Button { preset(item.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Duplicate existing") {
                    ForEach(devices) { item in
                        Button { duplicate(item.path) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name.isEmpty ? item.id : item.name)
                                Text(item.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Start a device")
            .frame(minWidth: 420, minHeight: 420)
        }
    }
}
