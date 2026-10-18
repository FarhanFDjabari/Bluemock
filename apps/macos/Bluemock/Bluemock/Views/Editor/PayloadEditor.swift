import SwiftUI

struct PayloadEditor: View {
    @Binding var payload: PayloadDefinition?
    var path: String? = nil
    private let kinds = ["u8", "u16le", "u16be", "u32le", "u32be", "i16le", "i16be", "i32le", "i32be", "ascii", "hex"]
    @State private var mode = "text"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Payload kind", selection: modeBinding) {
                Text("Text").tag("text")
                Text("Hex").tag("hex")
                Text("Bytes").tag("bytes")
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Payload kind")
            switch modeBinding.wrappedValue {
            case "text":
                TextField("Text template", text: textBinding)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Text payload template")
                    .id(path.map { $0 + ".text" } ?? "payload-text")
                Text("Templates support {expression} and {expression:fmt} placeholders.")
                    .font(.caption2).foregroundStyle(.secondary)
            case "hex":
                TextField("02 01 03", text: hexBinding)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hex payload template")
                    .id(path.map { $0 + ".hex" } ?? "payload-hex")
                Text("Hex templates support {expression:fmt} placeholders.")
                    .font(.caption2).foregroundStyle(.secondary)
            default:
                bytesEditor
            }
        }
        .onAppear { syncMode() }
        .onChange(of: payload?.content) { _, _ in syncMode() }
    }

    private var bytesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .bytes(let segments) = content {
                ForEach(segments.indices, id: \.self) { index in
                    HStack(spacing: 5) {
                        Picker("Segment kind", selection: segmentKindBinding(index)) {
                            ForEach(kinds, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 95)
                        .accessibilityLabel("Byte segment \(index + 1) kind")
                        TextField("Value or template", text: segmentValueBinding(index))
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Byte segment \(index + 1) value")
                        Button { moveSegment(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("Move segment up")
                        Button { moveSegment(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == segments.count - 1).accessibilityLabel("Move segment down")
                        Button(role: .destructive) { removeSegment(index) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove byte segment")
                    }
                }
            }
            Button("Add segment", systemImage: "plus") { appendSegment() }
                .buttonStyle(.borderless)
        }
    }

    private var modeBinding: Binding<String> {
        Binding(get: { mode }, set: { setMode($0) })
    }
    private var content: PayloadContent { payload?.content ?? .text("") }
    private var textBinding: Binding<String> {
        Binding(get: { if case .text(let value) = content { return value }; return "" }, set: { setContent(.text($0)) })
    }
    private var hexBinding: Binding<String> {
        Binding(get: { if case .hex(let value) = content { return value }; return "" }, set: { setContent(.hex($0)) })
    }

    private func segmentKindBinding(_ index: Int) -> Binding<String> {
        Binding(get: { byteSegments[safe: index]?.kind ?? "u8" }, set: { kind in
            var segments = byteSegments
            guard segments.indices.contains(index) else { return }
            segments[index].kind = kind
            setContent(.bytes(segments))
        })
    }
    private func segmentValueBinding(_ index: Int) -> Binding<String> {
        Binding(get: { byteSegments[safe: index].map { stringValue($0.value) } ?? "" }, set: { text in
            var segments = byteSegments
            guard segments.indices.contains(index) else { return }
            if segments[index].kind == "ascii" || segments[index].kind == "hex" {
                segments[index].value = .string(text)
            } else if segments[index].kind == "u8" || segments[index].kind.hasPrefix("u16") || segments[index].kind.hasPrefix("u32") || segments[index].kind.hasPrefix("i16") || segments[index].kind.hasPrefix("i32") {
                segments[index].value = Int(text).map(JSONValue.integer) ?? .string(text)
            } else {
                segments[index].value = Double(text).map(JSONValue.number) ?? .string(text)
            }
            setContent(.bytes(segments))
        })
    }
    private var byteSegments: [PayloadSegment] { if case .bytes(let values) = content { return values }; return [] }

    private func setMode(_ newMode: String) {
        mode = newMode
        switch newMode {
        case "hex": setContent(.hex(""))
        case "bytes": if case .bytes = content {} else { setContent(.bytes([])) }
        default: setContent(.text(""))
        }
    }

    private func setContent(_ newContent: PayloadContent) {
        var value = payload ?? PayloadDefinition()
        value.content = newContent
        payload = value
    }
    private func syncMode() {
        switch payload?.content {
        case .hex: mode = "hex"
        case .bytes: mode = "bytes"
        default: mode = "text"
        }
    }
    private func appendSegment() { setContent(.bytes(byteSegments + [PayloadSegment()])) }
    private func removeSegment(_ index: Int) {
        var values = byteSegments
        guard values.indices.contains(index) else { return }
        values.remove(at: index)
        setContent(.bytes(values))
    }
    private func moveSegment(_ index: Int, by offset: Int) {
        var values = byteSegments
        let target = index + offset
        guard values.indices.contains(index), values.indices.contains(target) else { return }
        values.swapAt(index, target)
        setContent(.bytes(values))
    }
    private func stringValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .integer(let number): String(number)
        case .number(let number): String(number)
        case .bool(let bool): bool ? "true" : "false"
        default: ""
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
