import SwiftUI

private nonisolated struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let event: IPCEvent
}

private nonisolated struct ContentBottomPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    nonisolated static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct EventLog: View {
    let process: DeviceProcess
    @State private var entries: [LogEntry] = []
    @State private var textMode = true
    @State private var followsBottom = true
    @State private var lastSeenRevision = 0
    @State private var logRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Log payload format", selection: $textMode) {
                    Text("Text").tag(true)
                    Text("Hex").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 104)
                .accessibilityLabel("Log payload format")
                Button("Clear") {
                    entries.removeAll()
                    process.session.clearEventLog()
                }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear event log")
            }

            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(entries) { entry in
                                logRow(entry.event)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: ContentBottomPreference.self,
                                                       value: content.frame(in: .named("event-log-scroll")).maxY)
                            }
                        }
                    }
                    .coordinateSpace(name: "event-log-scroll")
                    .onPreferenceChange(ContentBottomPreference.self) { bottom in
                        followsBottom = bottom <= viewport.size.height + 4
                    }
                    .onChange(of: logRevision) { _, _ in
                        guard followsBottom, let last = entries.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .frame(height: 132)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Device event log")
        }
        .onAppear {
            entries = process.events.filter { $0.sequence > process.session.eventLogClearSequence }
                .suffix(50).map { LogEntry(event: $0) }
            lastSeenRevision = process.eventRevision
            logRevision += 1
        }
        .onChange(of: process.eventRevision) { _, revision in
            let unseenCount = min(max(0, revision - lastSeenRevision), process.events.count)
            guard unseenCount > 0 else { lastSeenRevision = revision; return }
            let unseen = process.events.suffix(unseenCount)
                .filter { $0.sequence > process.session.eventLogClearSequence }
            entries.append(contentsOf: unseen.map { LogEntry(event: $0) })
            lastSeenRevision = revision
            if entries.count > 50 { entries.removeFirst(entries.count - 50) }
            logRevision += 1
        }
    }

    private func logRow(_ event: IPCEvent) -> some View {
        let parts = rowText(event)
        let secondary: Bool
        switch event.kind {
        case .connected, .disconnected, .subscribed, .log: secondary = true
        default: secondary = false
        }
        return HStack(alignment: .top, spacing: 6) {
            Text(time(event)).foregroundStyle(.tertiary)
            Text(parts.kind).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            Text(parts.message).foregroundStyle(event.kind == .error ? Color.red : secondary ? Color.secondary : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(time(event)), \(parts.kind), \(parts.message)")
    }

    private func rowText(_ event: IPCEvent) -> (kind: String, message: String) {
        let fields = event.fields
        switch event.kind {
        case .rx, .tx:
            let characteristic = fields["characteristic"]?.stringValue ?? "?"
            let payload: String
            if textMode, let text = fields["text"]?.stringValue { payload = escapeControls(text) }
            else { payload = fields["hex"]?.stringValue ?? "" }
            return (event.kind == .rx ? "RX" : "TX", "\(characteristic) · \(payload)")
        case .connected: return ("CONNECT", fields["peer"]?.stringValue ?? "Central connected")
        case .disconnected: return ("DISCONNECT", fields["peer"]?.stringValue ?? "Central disconnected")
        case .subscribed:
            let id = fields["characteristic"]?.stringValue ?? "?"
            let notify = fields["notify"]?.boolValue == true ? "notify" : ""
            let indicate = fields["indicate"]?.boolValue == true ? "indicate" : ""
            return ("SUBSCRIBE", [id, notify, indicate].filter { !$0.isEmpty }.joined(separator: " · "))
        case .error: return ("ERROR", fields["message"]?.stringValue ?? "Device error")
        case .log: return ("LOG", fields["message"]?.stringValue ?? "")
        case .state: return ("STATE", "State updated")
        case .advertising: return ("ADVERTISE", "Advertising started")
        case .ready: return ("READY", "Device ready")
        case .stopped: return ("STOPPED", "Device stopped")
        case .unknown: return (event.eventName.uppercased(), "")
        }
    }

    private func time(_ event: IPCEvent) -> String {
        guard let timestamp = event.fields["ts"]?.stringValue,
              let separator = timestamp.firstIndex(of: "T") else { return "--:--:--" }
        return String(timestamp[timestamp.index(after: separator)...].prefix(8))
    }

    private func escapeControls(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 9: "\\t"
            case 10: "\\n"
            case 13: "\\r"
            case 0..<32, 127: String(format: "\\x%02X", scalar.value)
            default: String(scalar)
            }
        }.joined()
    }
}

private extension JSONValue {
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
}
