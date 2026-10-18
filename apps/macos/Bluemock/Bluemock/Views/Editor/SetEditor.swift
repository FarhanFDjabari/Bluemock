import SwiftUI

struct SetEditor: View {
    @Binding var assignments: [String: JSONValue]
    let stateKeys: [String]
    let path: String
    let issues: [EditorValidationIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set state").font(.caption).foregroundStyle(.secondary)
            ForEach(assignments.keys.sorted(), id: \.self) { target in
                HStack(spacing: 5) {
                    Picker("State variable", selection: targetBinding(target)) {
                        if !stateKeys.contains(target) { Text(target).tag(target) }
                        ForEach(stateKeys, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 125)
                    .accessibilityLabel("Assigned state variable")
                    .id("\(path).set.\(target)")
                    TextField("Expression", text: expressionBinding(target))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Expression assigned to \(target)")
                        .id("\(path).set.\(target)")
                    Button(role: .destructive) { assignments.removeValue(forKey: target) } label: {
                        Image(systemName: "minus.circle")
                    }.accessibilityLabel("Remove state assignment")
                }
                ValidationMessage(path: "\(path).set.\(target)", issues: issues)
            }
            Button("Add assignment", systemImage: "plus", action: addAssignment)
                .buttonStyle(.borderless)
        }
    }

    private func targetBinding(_ old: String) -> Binding<String> {
        Binding(get: { old }, set: { target in
            guard target != old, let expression = assignments.removeValue(forKey: old) else { return }
            assignments[target] = expression
        })
    }

    private func expressionBinding(_ target: String) -> Binding<String> {
        Binding(get: { scalarText(assignments[target] ?? .string("0")) }, set: { assignments[target] = .string($0) })
    }

    private func addAssignment() {
        let target = stateKeys.first(where: { assignments[$0] == nil }) ?? "state_var"
        assignments[target] = .string("0")
    }

    private func scalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): string
        case .integer(let number): String(number)
        case .number(let number): String(number)
        case .bool(let bool): bool ? "true" : "false"
        default: ""
        }
    }
}
