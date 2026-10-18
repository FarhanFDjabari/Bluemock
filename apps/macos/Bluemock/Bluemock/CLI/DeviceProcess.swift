import Foundation
import Observation
import Darwin

@MainActor @Observable
final class DeviceProcess: Identifiable {
    enum Status: Equatable {
        case stopped, starting, advertising, connected(String), error(String)
    }

    let id: String
    let definitionPath: String
    let cli: CLILocation
    let transport: String?
    private(set) var status: Status = .stopped
    private(set) var events: [IPCEvent] = []
    private(set) var stateValues: [String: JSONValue] = [:]
    private(set) var devicePayload: JSONValue?
    private(set) var stderrLines: [String] = []
    private(set) var lastFatalError: String?
    private var process: Process?
    private var stdin: FileHandle?
    @ObservationIgnored private nonisolated(unsafe) var stdoutBuffer = Data()
    @ObservationIgnored private nonisolated(unsafe) var stderrBuffer = Data()
    private let ioQueue = DispatchQueue(label: "io.github.farhanfdjabari.bluemock.process")
    var isRunning: Bool { process?.isRunning == true }

    init(summary: DeviceSummary, cli: CLILocation, transport: String?) {
        id = summary.id
        definitionPath = summary.path
        self.cli = cli
        self.transport = transport
    }

    func start() {
        guard process == nil, status == .stopped else { return }
        status = .starting
        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = cli.executable
        child.arguments = ["run", definitionPath, "--ipc"] + (transport.map { ["--transport", $0] } ?? [])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = cli.loginPath
        child.environment = environment
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        process = child
        stdin = input.fileHandleForWriting
        let eventQueue = ioQueue

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                eventQueue.async { [weak self] in self?.consumeStdout(Data(), final: true) }
                return
            }
            eventQueue.async { [weak self] in self?.consumeStdout(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                eventQueue.async { [weak self] in self?.consumeStderr(Data(), final: true) }
                return
            }
            eventQueue.async { [weak self] in self?.consumeStderr(data) }
        }
        child.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in self?.didExit(code: process.terminationStatus) }
        }
        do { try child.run() }
        catch {
            process = nil
            status = .error(error.localizedDescription)
        }
    }

    private nonisolated func consumeStdout(_ data: Data, final: Bool = false) {
        stdoutBuffer.append(data)
        var decoded: [IPCEvent] = []
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            if let event = try? JSONDecoder().decode(IPCEvent.self, from: line) { decoded.append(event) }
        }
        if final, !stdoutBuffer.isEmpty {
            if let event = try? JSONDecoder().decode(IPCEvent.self, from: stdoutBuffer) { decoded.append(event) }
            stdoutBuffer.removeAll(keepingCapacity: true)
        }
        guard !decoded.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                decoded.forEach { self.apply($0) }
            }
        }
    }

    private nonisolated func consumeStderr(_ data: Data, final: Bool = false) {
        stderrBuffer.append(data)
        var lines: [String] = []
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            let line = Data(stderrBuffer[..<newline])
            stderrBuffer.removeSubrange(...newline)
            lines.append(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines))
        }
        if final, !stderrBuffer.isEmpty {
            lines.append(String(decoding: stderrBuffer, as: UTF8.self).trimmingCharacters(in: .newlines))
            stderrBuffer.removeAll(keepingCapacity: true)
        }
        guard !lines.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stderrLines = Array((self.stderrLines + lines).suffix(8))
            }
        }
    }

    private func apply(_ event: IPCEvent) {
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        switch event.kind {
        case .ready: devicePayload = event.fields["device"]
        case .advertising: status = .advertising
        case .connected: status = .connected(event.fields["peer"]?.stringValue ?? "Central")
        case .disconnected: status = .advertising
        case .state: stateValues = event.fields["values"]?.objectValue ?? stateValues
        case .error:
            let message = event.fields["message"]?.stringValue ?? "Unknown device error"
            if case .bool(true) = event.fields["fatal"] { lastFatalError = message; status = .error(message) }
        case .stopped: break
        case .subscribed, .rx, .tx, .log, .unknown: break
        }
    }

    func send(_ command: IPCCommand) {
        guard isRunning, let stdin, let data = try? JSONEncoder().encode(command) else { return }
        do { try stdin.write(contentsOf: data + Data([0x0A])) }
        catch { status = .error("Could not send command: \(error.localizedDescription)") }
    }

    func stop() async {
        guard let process else { status = .stopped; return }
        send(.stop())
        if await waitForExit(process, seconds: 2) { status = .stopped; return }
        kill(process.processIdentifier, SIGTERM)
        if await waitForExit(process, seconds: 3) { status = .stopped; return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForExit(process, seconds: 1)
        status = .stopped
    }

    func stopSynchronously() {
        guard let process, process.isRunning else { return }
        if let data = try? JSONEncoder().encode(IPCCommand.stop()) { try? stdin?.write(contentsOf: data + Data([0x0A])) }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGTERM) }
        let termDeadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < termDeadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func waitForExit(_ process: Process, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return !process.isRunning
    }

    private func didExit(code: Int32) {
        stdin = nil
        process = nil
        if code == 0 { status = .stopped }
        else if case .error = status { }
        else { status = .error(lastFatalError ?? stderrLines.last ?? "Process exited with status \(code)") }
    }
}
