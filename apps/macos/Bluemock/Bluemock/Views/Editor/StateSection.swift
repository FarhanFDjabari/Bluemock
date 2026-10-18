import SwiftUI

struct StateSection: View {
    @Binding var definition: DeviceDefinition
    let issues: [EditorValidationIssue]

    var body: some View {
        Section {
            ForEach(definition.state.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        TextField("Variable", text: keyBinding(key))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("State variable name")
                            .id("state.\(key)")
                        Picker("State type", selection: typeBinding(key)) {
                            Text("Number").tag("number")
                            Text("String").tag("string")
                            Text("Boolean").tag("boolean")
                        }
                        .frame(width: 105)
                        .accessibilityLabel("State type for \(key)")
                        if case .bool = definition.state[key] {
                            Toggle("", isOn: boolBinding(key)).labelsHidden().accessibilityLabel("Value of \(key)")
                        } else {
                            TextField("Value", text: valueBinding(key))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Value of state variable \(key)")
                        }
                        Button(role: .destructive) { definition.state.removeValue(forKey: key) } label: {
                            Image(systemName: "minus.circle")
                        }.accessibilityLabel("Remove state variable \(key)")
                    }
                    ValidationMessage(path: "state.\(key)", issues: issues)
                }
            }
            Button("Add state variable", systemImage: "plus", action: addVariable)
        } header: { Text("State") }
    }

    private func keyBinding(_ key: String) -> Binding<String> {
        Binding(get: { key }, set: { newKey in
            guard newKey != key else { return }
            let oldValue = definition.state.removeValue(forKey: key)
            if !newKey.isEmpty, let oldValue { definition.state[newKey] = oldValue }
        })
    }
    private func typeBinding(_ key: String) -> Binding<String> {
        Binding(get: { stateType(definition.state[key] ?? .integer(0)) }, set: { newType in
            let old = definition.state[key] ?? .number(0)
            switch newType {
            case "string": definition.state[key] = .string(string(from: old))
            case "boolean": definition.state[key] = .bool(boolean(from: old))
            default: definition.state[key] = oldNumberOrInt(number(from: old) ?? 0)
            }
        })
    }
    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(get: { string(from: definition.state[key] ?? .string("")) }, set: { text in
            if let number = Double(text), number.isFinite { definition.state[key] = .number(number) }
            else { definition.state[key] = .string(text) }
        })
    }
    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { boolean(from: definition.state[key] ?? .bool(false)) }, set: { definition.state[key] = .bool($0) })
    }
    private func addVariable() {
        var suffix = 1
        while definition.state["state_\(suffix)"] != nil { suffix += 1 }
        definition.state["state_\(suffix)"] = .integer(0)
    }
    private func stateType(_ value: JSONValue) -> String {
        switch value { case .number, .integer: "number"; case .string: "string"; case .bool: "boolean"; default: "string" }
    }
    private func string(from value: JSONValue) -> String {
        switch value { case .string(let text): text; case .integer(let number): String(number); case .number(let number): String(number); case .bool(let bool): bool ? "true" : "false"; default: "" }
    }
    private func number(from value: JSONValue) -> Double? {
        switch value { case .number(let number): number; case .integer(let number): Double(number); case .string(let text): Double(text); default: nil }
    }
    private func oldNumberOrInt(_ number: Double) -> JSONValue {
        number.rounded() == number ? (Int(exactly: number).map(JSONValue.integer) ?? .number(number)) : .number(number)
    }
    private func boolean(from value: JSONValue) -> Bool { if case .bool(let bool) = value { return bool }; return false }
}
