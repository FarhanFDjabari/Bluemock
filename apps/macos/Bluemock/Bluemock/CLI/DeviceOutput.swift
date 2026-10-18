import Foundation

/// Readability callbacks synchronously enter this queue so raw Data cannot pile up in dispatch work.
nonisolated final class DeviceOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bluemock.output")
    private let slots = DispatchSemaphore(value: Limits.maxPendingEventBatches)
    private var stdout = Data()
    private var stderr = Data()
    private var droppingLine = false
    private let dropLock = NSLock()
    private var dropped = 0
    private let deliver: @MainActor @Sendable ([IPCEvent], [String]) -> Void

    init(deliver: @escaping @MainActor @Sendable ([IPCEvent], [String]) -> Void) { self.deliver = deliver }

    func consume(_ data: Data, isOutput: Bool, final: Bool) {
        queue.sync {
            if isOutput { consumeOutput(data, final: final) }
            else {
                stderr.append(data)
                if stderr.count > Limits.maxStderrBytes { stderr = Data(stderr.suffix(Limits.maxStderrBytes)) }
                var lines: [String] = []
                while let newline = stderr.firstIndex(of: 10) {
                    lines.append(String(decoding: stderr[..<newline], as: UTF8.self))
                    stderr.removeSubrange(...newline)
                }
                if final, !stderr.isEmpty { lines.append(String(decoding: stderr, as: UTF8.self)); stderr.removeAll() }
                if !lines.isEmpty { submit([], lines: Array(lines.suffix(Limits.maxStderrLines))) }
            }
        }
    }

    private func consumeOutput(_ data: Data, final: Bool) {
        // Split before appending: even one oversized read cannot inflate the partial-line buffer.
        let segments = data.split(separator: 10, omittingEmptySubsequences: false)
        for segment in segments.enumerated() {
            let hasNewline = segment.offset < segments.count - 1
            if !droppingLine {
                if stdout.count + segment.element.count > Limits.maxIPCLineBytes {
                    stdout.removeAll()
                    droppingLine = true
                    submit([message("Device output line exceeds the 1 MiB limit; line discarded.", error: true)])
                } else { stdout.append(contentsOf: segment.element) }
            }
            if hasNewline {
                decodeLine()
                droppingLine = false
            }
        }
        if final { decodeLine(); droppingLine = false }
    }

    private func decodeLine() {
        if !droppingLine, !stdout.isEmpty, let event = try? JSONDecoder().decode(IPCEvent.self, from: stdout) {
            submit([event])
        }
        stdout.removeAll(keepingCapacity: true)
    }

    private func message(_ text: String, error: Bool = false) -> IPCEvent {
        IPCEvent(kind: error ? .error : .log, eventName: error ? "error" : "log", fields: ["message": .string(text)])
    }

    private func submit(_ events: [IPCEvent], lines: [String] = []) {
        let disposable = events.allSatisfy { [.rx, .tx, .log].contains($0.kind) }
        if slots.wait(timeout: .now()) != .success {
            if disposable {
                dropLock.lock(); dropped += max(events.count, lines.count); dropLock.unlock()
                return
            }
            // Critical events apply backpressure to the reader, never to the main actor.
            slots.wait()
        }
        DispatchQueue.main.async { [self] in
            dropLock.lock(); let count = dropped; dropped = 0; dropLock.unlock()
            MainActor.assumeIsolated {
                var delivery = events
                if count > 0 { delivery.insert(message("\(count) events dropped while the log was busy."), at: 0) }
                deliver(delivery, lines)
            }
            slots.signal()
        }
    }
}
