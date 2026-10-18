import SwiftUI

struct ServicesSection: View {
    @Binding var definition: DeviceDefinition
    let issues: [EditorValidationIssue]
    private let properties = ["read", "write", "write_without_response", "notify", "indicate"]

    var body: some View {
        Section {
            ForEach(definition.services.indices, id: \.self) { index in
                serviceEditor(index)
            }
            Button("Add service", systemImage: "plus", action: addService)
        } header: { Text("Services and characteristics") }
    }

    private func serviceEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Service \(index + 1)").font(.subheadline.weight(.medium))
                Spacer()
                Button { moveService(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).accessibilityLabel("Move service up")
                Button { moveService(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == definition.services.count - 1).accessibilityLabel("Move service down")
                Button(role: .destructive) {
                    definition.services.remove(at: index)
                    syncAdvertisedServices()
                } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove service")
            }
            HStack {
                UUIDPicker(uuid: $definition.services[index].uuid, options: WellKnownUUIDs.services,
                           label: "Service", path: "services[\(index)].uuid")
                Toggle("Primary", isOn: primaryBinding(index))
                    .accessibilityLabel("Primary service")
                    .id("services[\(index)].primary")
            }
            ValidationMessage(path: "services[\(index)].uuid", issues: issues)
            ForEach(definition.services[index].characteristics.indices, id: \.self) { charIndex in
                characteristicEditor(serviceIndex: index, characteristicIndex: charIndex)
            }
            ValidationMessage(path: "services[\(index)].characteristics", issues: issues)
            Button("Add characteristic", systemImage: "plus") { addCharacteristic(to: index) }
                .buttonStyle(.borderless)
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func characteristicEditor(serviceIndex: Int, characteristicIndex: Int) -> some View {
        let path = "services[\(serviceIndex)].characteristics[\(characteristicIndex)]"
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button { moveCharacteristic(serviceIndex, characteristicIndex, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(characteristicIndex == 0).accessibilityLabel("Move characteristic up")
                TextField("Characteristic id", text: $definition.services[serviceIndex].characteristics[characteristicIndex].characteristicID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Characteristic id")
                    .id(path + ".id")
                UUIDPicker(uuid: $definition.services[serviceIndex].characteristics[characteristicIndex].uuid,
                           options: WellKnownUUIDs.characteristics, label: "Characteristic", path: path + ".uuid")
                Button { moveCharacteristic(serviceIndex, characteristicIndex, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(characteristicIndex == definition.services[serviceIndex].characteristics.count - 1)
                    .accessibilityLabel("Move characteristic down")
                Button(role: .destructive) {
                    definition.services[serviceIndex].characteristics.remove(at: characteristicIndex)
                } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove characteristic")
            }
            ValidationMessage(path: path + ".id", issues: issues)
            ValidationMessage(path: path + ".uuid", issues: issues)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), alignment: .leading)], alignment: .leading) {
                ForEach(properties, id: \.self) { property in
                    Toggle(propertyLabel(property), isOn: propertyBinding(serviceIndex, characteristicIndex, property))
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("\(propertyLabel(property)) property")
                }
            }
            ValidationMessage(path: path + ".properties", issues: issues)
            HStack {
                Toggle("Initial payload", isOn: initialEnabledBinding(serviceIndex, characteristicIndex))
                    .accessibilityLabel("Set initial read payload")
                Picker("Encoding", selection: $definition.services[serviceIndex].characteristics[characteristicIndex].encoding) {
                    Text("Text").tag("text"); Text("Hex").tag("hex")
                }
                .frame(width: 110)
                .accessibilityLabel("Characteristic encoding")
                .id(path + ".encoding")
            }
            if definition.services[serviceIndex].characteristics[characteristicIndex].initial != nil {
                PayloadEditor(payload: $definition.services[serviceIndex].characteristics[characteristicIndex].initial,
                              path: path + ".initial")
                ValidationMessage(path: path + ".initial", issues: issues)
            }
        }
        .padding(.leading, 8)
    }

    private func propertyBinding(_ service: Int, _ characteristic: Int, _ property: String) -> Binding<Bool> {
        Binding(get: { definition.services[service].characteristics[characteristic].properties.contains(property) }, set: { enabled in
            var values = definition.services[service].characteristics[characteristic].properties
            if enabled, !values.contains(property) { values.append(property) }
            if !enabled { values.removeAll { $0 == property } }
            definition.services[service].characteristics[characteristic].properties = values
        })
    }

    private func initialEnabledBinding(_ service: Int, _ characteristic: Int) -> Binding<Bool> {
        Binding(get: { definition.services[service].characteristics[characteristic].initial != nil }, set: { enabled in
            definition.services[service].characteristics[characteristic].initial = enabled ? PayloadDefinition() : nil
        })
    }

    private func addService() {
        let suffix = definition.services.count + 1
        definition.services.append(ServiceDefinition(uuid: "FFE0", characteristics: [
            CharacteristicDefinition(characteristicID: "characteristic\(suffix)", uuid: "FFE1", properties: ["notify", "write_without_response"])
        ]))
        syncAdvertisedServices()
    }
    private func addCharacteristic(to service: Int) {
        let suffix = definition.services[service].characteristics.count + 1
        definition.services[service].characteristics.append(
            CharacteristicDefinition(characteristicID: "characteristic\(suffix)", uuid: "FFE1", properties: ["notify"])
        )
    }
    private func moveService(_ index: Int, by delta: Int) {
        let target = index + delta
        guard definition.services.indices.contains(target) else { return }
        definition.services.swapAt(index, target)
        syncAdvertisedServices()
    }
    private func moveCharacteristic(_ service: Int, _ index: Int, by delta: Int) {
        let target = index + delta
        guard definition.services[service].characteristics.indices.contains(target) else { return }
        definition.services[service].characteristics.swapAt(index, target)
    }
    private func propertyLabel(_ property: String) -> String { property.replacingOccurrences(of: "_", with: " ") }
    private func primaryBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { definition.services[index].primary }, set: { definition.services[index].primary = $0; syncAdvertisedServices() })
    }
    private func syncAdvertisedServices() {
        guard definition.advertising.followsPrimaryServices else { return }
        definition.advertising.service_uuids = definition.services.filter(\.primary).map(\.uuid)
    }
}
