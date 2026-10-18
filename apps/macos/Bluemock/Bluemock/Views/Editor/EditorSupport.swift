import SwiftUI

struct ValidationMessage: View {
    let path: String
    let issues: [EditorValidationIssue]
    private var messages: [String] { issues.filter { $0.path == path }.map(\.message) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(messages.indices, id: \.self) { index in
                Text(messages[index]).font(.caption2).foregroundStyle(.red)
            }
        }
        .id(path)
        .accessibilityLabel(messages.joined(separator: ". "))
    }
}

struct ValidationSummary: View {
    let issues: [EditorValidationIssue]
    let scroll: (String) -> Void

    var body: some View {
        if !issues.isEmpty {
            Section("Validation errors") {
                ForEach(issues) { issue in
                    Button { scroll(issue.path) } label: {
                        Text("\(issue.path): \(issue.message)")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Validation error at \(issue.path): \(issue.message)")
                }
            }
        }
    }
}

struct CharacteristicPicker: View {
    @Binding var selection: String
    let definition: DeviceDefinition
    let requiredProperties: Set<String>
    let label: String
    var path: String? = nil

    private var options: [CharacteristicDefinition] {
        definition.services.flatMap(\.characteristics).filter {
            requiredProperties.isEmpty || !requiredProperties.isDisjoint(with: $0.properties)
        }
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { characteristic in
                Text("\(characteristic.characteristicID) · \(characteristic.uuid)").tag(characteristic.characteristicID)
            }
        }
        .accessibilityLabel(label)
        .id(path ?? label)
    }
}

enum EditorActionIDs {
    static let reserved: Set<String> = ["send", "set", "state", "drop", "help", "quit", "exit"]
}
