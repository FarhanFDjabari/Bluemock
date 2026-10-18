import SwiftUI

struct AdvertisingSection: View {
    @Binding var definition: DeviceDefinition
    let issues: [EditorValidationIssue]
    @State private var uuidDraft = ""

    var body: some View {
        Section("Advertising") {
            TextField("Interval (ms)", value: $definition.advertising.interval_ms, format: .number)
                .accessibilityLabel("Advertising interval in milliseconds")
                .id("advertising.interval_ms")
            ValidationMessage(path: "advertising.interval_ms", issues: issues)
            Text("Advertised service UUIDs").font(.caption).foregroundStyle(.secondary)
            ForEach(definition.advertising.service_uuids.indices, id: \.self) { index in
                HStack {
                    UUIDPicker(uuid: serviceUUIDBinding(index), options: WellKnownUUIDs.services,
                               label: "Advertising service", path: "advertising.service_uuids[\(index)]")
                    Button(role: .destructive) {
                        definition.advertising.service_uuids.remove(at: index)
                        definition.advertising.followsPrimaryServices = false
                    } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel("Remove advertised service UUID")
                }
            }
            HStack {
                TextField("UUID to add", text: $uuidDraft).font(.system(.caption, design: .monospaced))
                    .accessibilityLabel("New advertised service UUID")
                Menu {
                    ForEach(WellKnownUUIDs.services) { item in Button(item.name) { uuidDraft = item.uuid; appendUUID() } }
                } label: { Image(systemName: "chevron.down.circle") }
                    .accessibilityLabel("Choose known advertised service UUID")
                Button("Add", systemImage: "plus", action: appendUUID).disabled(!WellKnownUUIDs.isValid(uuidDraft))
            }
            ForEach(issues.filter { $0.path.hasPrefix("advertising.service_uuids") }) { issue in
                Text("\(issue.path): \(issue.message)").font(.caption2).foregroundStyle(.red)
            }

            Toggle("Manufacturer data", isOn: manufacturerEnabled)
                .accessibilityLabel("Include manufacturer data")
            if definition.advertising.manufacturer_data != nil {
                TextField("Company id (0–65535)", value: companyBinding, format: .number)
                    .accessibilityLabel("Manufacturer company id")
                    .id("advertising.manufacturer_data.company_id")
                ValidationMessage(path: "advertising.manufacturer_data.company_id", issues: issues)
                TextField("Hex bytes", text: manufacturerHex)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Manufacturer data hex bytes")
                    .id("advertising.manufacturer_data.hex")
                ValidationMessage(path: "advertising.manufacturer_data.hex", issues: issues)
            }
        }
    }

    private var manufacturerEnabled: Binding<Bool> {
        Binding(get: { definition.advertising.manufacturer_data != nil }, set: {
            definition.advertising.manufacturer_data = $0 ? ManufacturerDataDefinition(company_id: 0, hex: "") : nil
        })
    }
    private var companyBinding: Binding<Int> {
        Binding(get: { definition.advertising.manufacturer_data?.company_id ?? 0 }, set: { definition.advertising.manufacturer_data?.company_id = $0 })
    }
    private var manufacturerHex: Binding<String> {
        Binding(get: { definition.advertising.manufacturer_data?.hex ?? "" }, set: { definition.advertising.manufacturer_data?.hex = $0 })
    }
    private func appendUUID() {
        guard WellKnownUUIDs.isValid(uuidDraft), !definition.advertising.service_uuids.contains(uuidDraft) else { return }
        definition.advertising.service_uuids.append(uuidDraft)
        definition.advertising.followsPrimaryServices = false
        uuidDraft = ""
    }
    private func serviceUUIDBinding(_ index: Int) -> Binding<String> {
        Binding(get: { definition.advertising.service_uuids[index] }, set: { value in
            definition.advertising.service_uuids[index] = value
            definition.advertising.followsPrimaryServices = false
        })
    }
}
