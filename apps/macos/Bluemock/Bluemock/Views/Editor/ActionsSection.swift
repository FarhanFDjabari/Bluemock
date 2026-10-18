import SwiftUI

struct ActionsSection: View {
    @Binding var definition: DeviceDefinition
    let issues: [EditorValidationIssue]

    var body: some View {
        Section {
            ForEach(definition.actions.indices, id: \.self) { index in actionEditor(index) }
            Button("Add action", systemImage: "plus", action: addAction)
        } header: { Text("Actions") }
    }

    private func actionEditor(_ index: Int) -> some View {
        let action = $definition.actions[index]
        let path = "actions[\(index)]"
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Action \(index + 1)").font(.subheadline.weight(.medium))
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).accessibilityLabel("Move action up")
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == definition.actions.count - 1).accessibilityLabel("Move action down")
                Button(role: .destructive) { definition.actions.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove action")
            }
            TextField("Action id", text: action.id).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Action id").id(path + ".id")
            ValidationMessage(path: path + ".id", issues: issues)
            if EditorActionIDs.reserved.contains(action.wrappedValue.id) {
                Text("This action id is reserved for a built-in command.").font(.caption2).foregroundStyle(.red)
            }
            TextField("Label", text: action.label).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Action label").id(path + ".label")
            Text("Parameters").font(.caption).foregroundStyle(.secondary)
            ForEach(action.wrappedValue.params.indices, id: \.self) { parameterIndex in
                parameterEditor(action.params[parameterIndex], actionIndex: index, parameterIndex: parameterIndex,
                                actionID: action.wrappedValue.id, count: action.wrappedValue.params.count)
            }
            Button("Add parameter", systemImage: "plus") { action.wrappedValue.params.append(ActionParameterDefinition()) }
                .buttonStyle(.borderless)
            SetEditor(assignments: action.setValues, stateKeys: definition.state.keys.sorted(), path: path, issues: issues)
            Toggle("Send payload", isOn: sendEnabled(action))
                .accessibilityLabel("Enable action send payload")
            if action.wrappedValue.send != nil {
                CharacteristicPicker(selection: sendCharacteristic(action), definition: definition,
                                     requiredProperties: ["notify", "indicate"], label: "Send characteristic",
                                     path: path + ".send.characteristic")
                PayloadEditor(payload: action.send, path: path + ".send")
                ValidationMessage(path: path + ".send", issues: issues)
            }
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func parameterEditor(_ parameter: Binding<ActionParameterDefinition>, actionIndex: Int, parameterIndex: Int,
                                 actionID: String, count: Int) -> some View {
        let path = "actions[\(actionIndex)].params[\(parameterIndex)]"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                TextField("Name", text: parameter.name).frame(minWidth: 75)
                    .accessibilityLabel("Parameter name").id(path + ".name")
                Picker("Type", selection: parameterType(parameter)) {
                    ForEach(["number", "integer", "string", "boolean", "choice"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 95).accessibilityLabel("Parameter type").id(path + ".type")
                TextField("Default", text: defaultText(parameter)).frame(minWidth: 70)
                    .accessibilityLabel("Parameter default").id(path + ".default")
                TextField("Min", value: parameter.minimum, format: .number).frame(width: 65)
                    .accessibilityLabel("Parameter minimum").id(path + ".min")
                TextField("Max", value: parameter.maximum, format: .number).frame(width: 65)
                    .accessibilityLabel("Parameter maximum").id(path + ".max")
                Button { moveParameter(actionIndex, parameterIndex, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(parameterIndex == 0).accessibilityLabel("Move parameter up")
                Button { moveParameter(actionIndex, parameterIndex, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(parameterIndex == count - 1).accessibilityLabel("Move parameter down")
                Button(role: .destructive) { removeParameter(actionIndex, parameterIndex) } label: {
                    Image(systemName: "minus.circle")
                }.accessibilityLabel("Remove parameter")
            }
            if parameter.wrappedValue.type == "choice" {
                TextField("Choices, comma separated", text: choicesText(parameter))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Parameter choices").id(path + ".choices")
            }
            ValidationMessage(path: path, issues: issues)
            ForEach(["name", "type", "default", "min", "max", "choices"], id: \.self) { field in
                ValidationMessage(path: path + "." + field, issues: issues)
            }
        }
    }

    private func parameterType(_ parameter: Binding<ActionParameterDefinition>) -> Binding<String> {
        Binding(get: { parameter.wrappedValue.type }, set: { type in
            parameter.wrappedValue.type = type
            if !["number", "integer", "choice"].contains(type) {
                parameter.wrappedValue.minimum = nil
                parameter.wrappedValue.maximum = nil
            }
            if type != "choice" { parameter.wrappedValue.choices = nil }
        })
    }

    private func defaultText(_ parameter: Binding<ActionParameterDefinition>) -> Binding<String> {
        Binding(get: { scalarText(parameter.wrappedValue.defaultValue) }, set: { text in
            if parameter.wrappedValue.type == "choice" {
                parameter.wrappedValue.defaultValue = parameter.wrappedValue.choices?.first(where: { scalarText($0) == text }) ?? parseScalar(text, type: "choice")
            } else {
                parameter.wrappedValue.defaultValue = parseScalar(text, type: parameter.wrappedValue.type)
            }
        })
    }
    private func choicesText(_ parameter: Binding<ActionParameterDefinition>) -> Binding<String> {
        Binding(get: { (parameter.wrappedValue.choices ?? []).map { scalarText($0) }.joined(separator: ", ") }, set: { text in
            parameter.wrappedValue.choices = text.split(separator: ",").map { part in
                let trimmed = String(part).trimmingCharacters(in: .whitespaces)
                return parseScalar(trimmed, type: parameter.wrappedValue.type) ?? .string(trimmed)
            }
        })
    }
    private func sendEnabled(_ action: Binding<ActionDefinition>) -> Binding<Bool> {
        Binding(get: { action.wrappedValue.send != nil }, set: { enabled in
            if enabled, action.wrappedValue.send == nil {
                let target = definition.services.flatMap(\.characteristics).first(where: { !Set(["notify", "indicate"]).isDisjoint(with: $0.properties) })?.characteristicID
                action.wrappedValue.send = PayloadDefinition(characteristic: target)
            } else if !enabled { action.wrappedValue.send = nil }
        })
    }
    private func sendCharacteristic(_ action: Binding<ActionDefinition>) -> Binding<String> {
        Binding(get: { action.wrappedValue.send?.characteristic ?? "" }, set: { action.wrappedValue.send?.characteristic = $0 })
    }
    private func addAction() { definition.actions.append(ActionDefinition()) }
    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard definition.actions.indices.contains(target) else { return }
        definition.actions.swapAt(index, target)
    }
    private func removeParameter(_ action: Int, _ parameter: Int) {
        definition.actions[action].params.remove(at: parameter)
    }
    private func moveParameter(_ action: Int, _ parameter: Int, by delta: Int) {
        let target = parameter + delta
        guard definition.actions[action].params.indices.contains(target) else { return }
        definition.actions[action].params.swapAt(parameter, target)
    }
    private func scalarText(_ value: JSONValue?) -> String {
        switch value { case .string(let value): value; case .integer(let value): String(value); case .number(let value): String(value); case .bool(let value): value ? "true" : "false"; default: "" }
    }
    private func parseScalar(_ text: String, type: String) -> JSONValue? {
        guard !text.isEmpty else { return nil }
        switch type {
        case "number": return Double(text).map(JSONValue.number) ?? .string(text)
        case "integer": return Int(text).map(JSONValue.integer) ?? .string(text)
        case "choice":
            if ["true", "yes"].contains(text.lowercased()) { return .bool(true) }
            if ["false", "no"].contains(text.lowercased()) { return .bool(false) }
            if let integer = Int(text) { return .integer(integer) }
            if let number = Double(text) { return .number(number) }
            return .string(text)
        case "boolean":
            if ["true", "yes", "1"].contains(text.lowercased()) { return .bool(true) }
            if ["false", "no", "0"].contains(text.lowercased()) { return .bool(false) }
            return .string(text)
        default: return .string(text)
        }
    }
}
