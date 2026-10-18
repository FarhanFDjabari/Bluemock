import SwiftUI

private enum ActionTimeout {
    static let withoutTransmission = Duration.seconds(1)
    static let withTransmission = Duration.seconds(3)
}

private struct ActionSpec {
    let id: String
    let label: String
    let params: [ParameterSpec]
    let hasSend: Bool

    init?(_ value: JSONValue) {
        guard let data = value.objectValue, let id = data["id"]?.stringValue else { return nil }
        self.id = id
        label = data["label"]?.stringValue ?? id
        params = (data["params"]?.arrayValue ?? []).compactMap(ParameterSpec.init)
        hasSend = data["send"] != nil
    }
}

private nonisolated struct ParameterSpec: Identifiable, Sendable {
    let id: String
    let type: String
    let defaultValue: JSONValue?
    let minimum: Double?
    let maximum: Double?
    let choices: [JSONValue]

    init?(_ value: JSONValue) {
        guard let data = value.objectValue,
              let name = data["name"]?.stringValue,
              let type = data["type"]?.stringValue else { return nil }
        id = name
        self.type = type
        defaultValue = data["default"]
        minimum = Self.number(data["min"])
        maximum = Self.number(data["max"])
        choices = data["choices"]?.arrayValue ?? []
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value { case .number(let number): number; case .integer(let number): Double(number); default: nil }
    }
}

struct ActionForm: View {
    let actionValue: JSONValue
    let process: DeviceProcess
    let session: DeviceSession
    @State private var submitError: String?

    private var action: ActionSpec? { ActionSpec(actionValue) }

    var body: some View {
        if let action {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(action.label).font(.caption.weight(.medium))
                    Text(action.id).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: submit) {
                        if case .success? = session.feedback[action.id] {
                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "paperplane")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.isPending(action.id))
                    .accessibilityLabel("Send action \(action.label)")
                }

                ForEach(action.params) { parameter in
                    parameterControl(parameter, action: action)
                }
                if let submitError {
                    Text(submitError).font(.caption2).foregroundStyle(.red)
                }
                if case .error(let message)? = session.feedback[action.id] {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .onAppear { session.ensureValues(actionID: action.id, params: action.params.map { ($0.id, $0.defaultValue) }) }
        }
    }

    @ViewBuilder
    private func parameterControl(_ parameter: ParameterSpec, action: ActionSpec) -> some View {
        switch parameter.type {
        case "number":
            VStack(alignment: .leading, spacing: 2) {
                TextField(parameter.id, value: numberBinding(parameter, action), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(action.label) \(parameter.id)")
                if let message = rangeError(parameter, action: action) {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
            }
        case "integer":
            HStack(spacing: 5) {
                Stepper("", value: integerBinding(parameter, action), in: integerRange(parameter))
                    .labelsHidden()
                    .accessibilityLabel("\(action.label) \(parameter.id)")
                TextField(parameter.id, value: integerBinding(parameter, action), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 70)
                    .accessibilityLabel("\(action.label) \(parameter.id)")
                if let message = rangeError(parameter, action: action) {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
            }
        case "string":
            TextField(parameter.id, text: stringBinding(parameter, action))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(action.label) \(parameter.id)")
        case "boolean":
            Toggle(parameter.id, isOn: booleanBinding(parameter, action))
                .accessibilityLabel("\(action.label) \(parameter.id)")
        case "choice":
            choiceControl(parameter, action: action)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func choiceControl(_ parameter: ParameterSpec, action: ActionSpec) -> some View {
        if parameter.choices.count <= 4 {
            Picker(parameter.id, selection: choiceBinding(parameter, action)) {
                ForEach(parameter.choices.indices, id: \.self) { index in
                    let choice = parameter.choices[index]
                    Text(choiceTitle(choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("\(action.label) \(parameter.id)")
        } else {
            Picker(parameter.id, selection: choiceBinding(parameter, action)) {
                ForEach(parameter.choices.indices, id: \.self) { index in
                    let choice = parameter.choices[index]
                    Text(choiceTitle(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("\(action.label) \(parameter.id)")
        }
    }

    private func numberBinding(_ parameter: ParameterSpec, _ action: ActionSpec) -> Binding<Double?> {
        Binding(get: { numeric(session.value(actionID: action.id, name: parameter.id)) },
                set: { session.setValue($0.map(JSONValue.number) ?? .string(""), actionID: action.id, name: parameter.id) })
    }

    private func integerBinding(_ parameter: ParameterSpec, _ action: ActionSpec) -> Binding<Int> {
        Binding(get: { integer(session.value(actionID: action.id, name: parameter.id)) ?? 0 },
                set: { session.setValue(.number(Double($0)), actionID: action.id, name: parameter.id) })
    }

    private func stringBinding(_ parameter: ParameterSpec, _ action: ActionSpec) -> Binding<String> {
        Binding(get: { session.value(actionID: action.id, name: parameter.id)?.stringValue ?? "" },
                set: { session.setValue(.string($0), actionID: action.id, name: parameter.id) })
    }

    private func booleanBinding(_ parameter: ParameterSpec, _ action: ActionSpec) -> Binding<Bool> {
        Binding(get: { if case .bool(let value) = session.value(actionID: action.id, name: parameter.id) { return value }; return false },
                set: { session.setValue(.bool($0), actionID: action.id, name: parameter.id) })
    }

    private func choiceBinding(_ parameter: ParameterSpec, _ action: ActionSpec) -> Binding<JSONValue> {
        Binding(get: { session.value(actionID: action.id, name: parameter.id) ?? parameter.choices.first ?? .null },
                set: { session.setValue($0, actionID: action.id, name: parameter.id) })
    }

    private func submit() {
        guard let action else { return }
        do {
            var params: [String: JSONValue] = [:]
            for parameter in action.params {
                guard let value = session.value(actionID: action.id, name: parameter.id) else {
                    if parameter.defaultValue == nil { throw FormError("\(parameter.id) is required") }
                    continue
                }
                params[parameter.id] = try typed(value, parameter: parameter)
            }
            guard let commandID = session.beginAction(action.id) else { return }
            submitError = nil
            process.send(.action(action.id, params: params))
            let timeout = action.hasSend ? ActionTimeout.withTransmission : ActionTimeout.withoutTransmission
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                session.expire(commandID: commandID)
            }
        } catch { submitError = error.localizedDescription }
    }

    private func typed(_ value: JSONValue, parameter: ParameterSpec) throws -> JSONValue {
        switch parameter.type {
        case "number":
            guard let number = numeric(value), number.isFinite else { throw FormError("Enter a valid number for \(parameter.id)") }
            try checkBounds(number, parameter)
            return .number(number)
        case "integer":
            guard let number = numeric(value), number.isFinite, number.rounded() == number else {
                throw FormError("Enter a whole number for \(parameter.id)")
            }
            try checkBounds(number, parameter)
            guard let integer = Int(exactly: number) else { throw FormError("\(parameter.id) is outside the supported integer range") }
            return .integer(integer)
        case "string": return .string(value.stringValue ?? "")
        case "boolean":
            guard case .bool = value else { throw FormError("Choose a boolean value for \(parameter.id)") }
            return value
        case "choice":
            guard parameter.choices.contains(value) else { throw FormError("Choose a listed value for \(parameter.id)") }
            if let number = numeric(value) { try checkBounds(number, parameter) }
            return value
        default: return value
        }
    }

    private func rangeError(_ parameter: ParameterSpec, action: ActionSpec) -> String? {
        guard let number = numeric(session.value(actionID: action.id, name: parameter.id)) else { return nil }
        if let minimum = parameter.minimum, number < minimum { return "Minimum \(minimum)" }
        if let maximum = parameter.maximum, number > maximum { return "Maximum \(maximum)" }
        return nil
    }

    private func integerRange(_ parameter: ParameterSpec) -> ClosedRange<Int> {
        let low = integerBound(parameter.minimum, lower: true)
        let high = max(low, integerBound(parameter.maximum, lower: false))
        return low...high
    }

    private func integerBound(_ value: Double?, lower: Bool) -> Int {
        guard let value, value.isFinite else { return lower ? -1_000_000_000 : 1_000_000_000 }
        if value <= Double(Int.min) { return Int.min }
        if value >= Double(Int.max) { return Int.max }
        return Int(lower ? ceil(value) : floor(value))
    }

    private func checkBounds(_ value: Double, _ parameter: ParameterSpec) throws {
        if let minimum = parameter.minimum, value < minimum { throw FormError("\(parameter.id) must be at least \(minimum)") }
        if let maximum = parameter.maximum, value > maximum { throw FormError("\(parameter.id) must be at most \(maximum)") }
    }

    private func numeric(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number): return number
        case .integer(let number): return Double(number)
        case .string(let string): return Double(string)
        default: return nil
        }
    }

    private func integer(_ value: JSONValue?) -> Int? {
        guard let number = numeric(value), number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    private func choiceTitle(_ choice: JSONValue) -> String {
        switch choice {
        case .string(let value): value
        case .integer(let value): String(value)
        case .number(let value): value.rounded() == value ? String(format: "%.0f", value) : String(value)
        case .bool(let value): value ? "Yes" : "No"
        default: "—"
        }
    }
}

private struct FormError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
