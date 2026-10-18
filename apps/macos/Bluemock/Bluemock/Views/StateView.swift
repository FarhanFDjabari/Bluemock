import SwiftUI

struct StateView: View {
    let values: [String: JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("State").font(.caption).foregroundStyle(.secondary)
            if values.isEmpty {
                Text("No state variables").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    if let value = values[key] {
                        HStack(alignment: .firstTextBaseline) {
                            Text(key).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(display(value))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let string): return "\(String(reflecting: string))"
        case .integer(let number): return String(number)
        case .number(let number):
            return number.rounded() == number ? String(format: "%.0f", number) : String(number)
        case .bool(let bool): return bool ? "true" : "false"
        case .null: return "null"
        case .object, .array: return String(describing: value)
        }
    }
}
