import SwiftUI

struct UUIDPicker: View {
    @Binding var uuid: String
    let options: [WellKnownUUID]
    let label: String
    var path: String? = nil
    @State private var selection = "custom"

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(options) { item in
                    Button("\(item.name) · \(item.uuid)") { uuid = item.uuid; selection = item.uuid }
                }
                Divider()
                Button("Custom") { selection = "custom" }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Choose \(label) UUID")
            TextField("UUID", text: $uuid)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("\(label) UUID")
                .id(path ?? label)
                .onChange(of: uuid) { _, value in
                    selection = options.first(where: { $0.uuid.caseInsensitiveCompare(value) == .orderedSame })?.uuid ?? "custom"
                }
        }
        if !WellKnownUUIDs.isValid(uuid) {
            Text("Use 4, 8, 32 hex digits or a dashed 128-bit UUID.")
                .font(.caption2).foregroundStyle(.red)
        }
    }
}
