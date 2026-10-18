import SwiftUI

struct RulesSection: View {
    @Binding var definition: DeviceDefinition
    let issues: [EditorValidationIssue]

    var body: some View {
        Section {
            Text("Rules are checked in order; the first match handles the write.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(definition.rules.indices, id: \.self) { index in
                ruleEditor(index)
            }
            Button("Add rule", systemImage: "plus", action: addRule)
        } header: { Text("Rules") }
    }

    private func ruleEditor(_ index: Int) -> some View {
        let rule = $definition.rules[index]
        let path = "rules[\(index)]"
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Rule \(index + 1)").font(.subheadline.weight(.medium))
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0).accessibilityLabel("Move rule up")
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == definition.rules.count - 1).accessibilityLabel("Move rule down")
                Button(role: .destructive) { definition.rules.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove rule")
            }
            CharacteristicPicker(selection: rule.on_write, definition: definition,
                                 requiredProperties: ["write", "write_without_response"], label: "On write characteristic",
                                 path: path + ".on_write")
            ValidationMessage(path: path + ".on_write", issues: issues)
            Picker("Match mode", selection: matchMode(rule)) {
                Text("Equals").tag("equals"); Text("Regex").tag("regex"); Text("Any").tag("any")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Rule match mode")
            .id(path + ".equals")
            if matchModeValue(rule.wrappedValue) != "any" {
                TextField(matchModeValue(rule.wrappedValue) == "equals" ? "Exact value" : "Regular expression", text: matchValue(rule))
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .accessibilityLabel("Rule match value")
                    .id(path + "." + matchModeValue(rule.wrappedValue))
                ValidationMessage(path: path + "." + matchModeValue(rule.wrappedValue), issues: issues)
            }
            Toggle("Trim whitespace before matching", isOn: rule.trim)
                .accessibilityLabel("Trim whitespace before matching")
                .id(path + ".trim")
            Toggle("Reply with a payload", isOn: replyEnabled(rule))
                .accessibilityLabel("Enable rule reply")
            if rule.wrappedValue.reply != nil {
                CharacteristicPicker(selection: replyCharacteristic(rule), definition: definition,
                                     requiredProperties: ["notify", "indicate"], label: "Reply characteristic",
                                     path: path + ".reply.characteristic")
                PayloadEditor(payload: rule.reply, path: path + ".reply")
                ValidationMessage(path: path + ".reply", issues: issues)
            }
            SetEditor(assignments: rule.setValues, stateKeys: definition.state.keys.sorted(), path: path, issues: issues)
        }
        .padding(9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func matchModeValue(_ rule: RuleDefinition) -> String {
        if rule.any == true { return "any" }
        return rule.regex != nil ? "regex" : "equals"
    }
    private func matchMode(_ rule: Binding<RuleDefinition>) -> Binding<String> {
        Binding(get: { matchModeValue(rule.wrappedValue) }, set: { mode in
            rule.wrappedValue.equals = mode == "equals" ? (rule.wrappedValue.equals ?? "") : nil
            rule.wrappedValue.regex = mode == "regex" ? (rule.wrappedValue.regex ?? "") : nil
            rule.wrappedValue.any = mode == "any" ? true : nil
        })
    }
    private func matchValue(_ rule: Binding<RuleDefinition>) -> Binding<String> {
        Binding(get: { matchModeValue(rule.wrappedValue) == "regex" ? (rule.wrappedValue.regex ?? "") : (rule.wrappedValue.equals ?? "") }, set: { value in
            if matchModeValue(rule.wrappedValue) == "regex" { rule.wrappedValue.regex = value } else { rule.wrappedValue.equals = value }
        })
    }
    private func replyEnabled(_ rule: Binding<RuleDefinition>) -> Binding<Bool> {
        Binding(get: { rule.wrappedValue.reply != nil }, set: { enabled in
            if enabled, rule.wrappedValue.reply == nil {
                let target = definition.services.flatMap(\.characteristics).first(where: { !Set(["notify", "indicate"]).isDisjoint(with: $0.properties) })?.characteristicID
                rule.wrappedValue.reply = PayloadDefinition(characteristic: target, content: .text(""))
            } else if !enabled { rule.wrappedValue.reply = nil }
        })
    }
    private func replyCharacteristic(_ rule: Binding<RuleDefinition>) -> Binding<String> {
        Binding(get: { rule.wrappedValue.reply?.characteristic ?? "" }, set: { rule.wrappedValue.reply?.characteristic = $0 })
    }
    private func addRule() {
        var rule = RuleDefinition()
        rule.on_write = definition.services.flatMap(\.characteristics).first(where: { !Set(["write", "write_without_response"]).isDisjoint(with: $0.properties) })?.characteristicID ?? ""
        rule.any = true
        definition.rules.append(rule)
    }
    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard definition.rules.indices.contains(target) else { return }
        definition.rules.swapAt(index, target)
    }
}
