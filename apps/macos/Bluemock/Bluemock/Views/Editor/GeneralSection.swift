import SwiftUI

struct GeneralSection: View {
    @Binding var definition: DeviceDefinition
    let issues: [EditorValidationIssue]

    var body: some View {
        Section("General") {
            TextField("Device id", text: $definition.id)
                .accessibilityLabel("Device id")
                .id("id")
            ValidationMessage(path: "id", issues: issues)
            TextField("Advertised name", text: $definition.name)
                .accessibilityLabel("Advertised name")
                .id("name")
            ValidationMessage(path: "name", issues: issues)
            TextField("Description", text: $definition.description, axis: .vertical)
                .lineLimit(2...4)
                .accessibilityLabel("Description")
            HStack {
                TextField("Random static address (optional)", text: addressBinding)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Bluetooth address")
                    .id("address")
                if definition.address != nil {
                    Button { definition.address = nil } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Clear Bluetooth address")
                }
            }
            Text("Omit to derive a stable random static address. Explicit addresses require a first octet C0–FF.")
                .font(.caption).foregroundStyle(.secondary)
            ValidationMessage(path: "address", issues: issues)
        }
    }

    private var addressBinding: Binding<String> {
        Binding(get: { definition.address ?? "" }, set: { definition.address = $0.isEmpty ? nil : $0 })
    }
}
