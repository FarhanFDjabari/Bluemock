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
    let session: DeviceSession
    private(set) var status: Status = .stopped
    private(set) var events: [IPCEvent] = []
    private(set) var eventRevision = 0
    private(set) var stateValues: [String: JSONValue] = [:]
    private(set) var devicePayload: JSONValue?
    private(set) var stderrLines: [String] = []
    private(set) var lastFatalError: String?
    private var process: Process?
    private var stdin: DeviceInput?
    private var outputReader: DeviceOutput?
    var isRunning: Bool { process?.isRunning == true }

    init(summary: DeviceSummary, cli: CLILocation, transport: String?, session: DeviceSession) {
        id = summary.id
        definitionPath = summary.path
        self.cli = cli
        self.transport = transport
        self.session = session
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
        stdin = DeviceInput(input.fileHandleForWriting)
        let reader = DeviceOutput { [weak self] events, lines in
            guard let self else { return }
            events.forEach { self.apply($0) }
            self.stderrLines = Array((self.stderrLines + lines).suffix(Limits.maxStderrLines))
            while self.stderrLines.reduce(0, { $0 + $1.utf8.count }) > Limits.maxStderrBytes {
                self.stderrLines.removeFirst()
            }
        }
        outputReader = reader
        for (handle, isOutput) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
            handle.readabilityHandler = { file in
                let data = file.availableData
                if data.isEmpty { file.readabilityHandler = nil }
                reader.consume(data, isOutput: isOutput, final: data.isEmpty)
            }
        }
        child.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in self?.didExit(code: process.terminationStatus) }
        }
        do { try child.run() }
        catch {
            process = nil
            session.clearPendingCommands()
            status = .error(error.localizedDescription)
        }
    }

    private func apply(_ incoming: IPCEvent) {
        let event = session.recordEvent(incoming)
        events.append(event)
        eventRevision += 1
        if events.count > Limits.maxVisibleEvents { events.removeFirst(events.count - Limits.maxVisibleEvents) }
        switch event.kind {
        case .ready:
            devicePayload = event.fields["device"]
            session.reconcileActions(devicePayload?.objectValue?["actions"]?.arrayValue ?? [])
            stateValues = event.fields["device"]?.objectValue?["state"]?.objectValue ?? stateValues
        case .advertising: status = .advertising
        case .connected: status = .connected(event.fields["peer"]?.stringValue ?? "Central")
        case .disconnected: status = .advertising
        case .state: stateValues = event.fields["values"]?.objectValue ?? stateValues
        case .error:
            let message = event.fields["message"]?.stringValue ?? "Unknown device error"
            if let replyTo = event.fields["reply_to"]?.stringValue {
                session.receiveError(replyTo: replyTo, message: message)
            }
            if case .bool(true) = event.fields["fatal"] { lastFatalError = message; status = .error(message) }
        case .tx:
            if event.fields["source"]?.stringValue == "action",
               let actionID = event.fields["ref"]?.stringValue {
                session.receiveTransmission(actionID: actionID)
            }
        case .stopped: break
        case .subscribed, .rx, .log, .unknown: break
        }
    }

    func send(_ command: IPCCommand) {
        guard isRunning, let stdin else { return }
        func report(_ message: String) {
            if let actionID = command.actionID { session.receiveError(replyTo: actionID, message: message) }
            apply(IPCEvent(kind: .error, eventName: "error", fields: ["message": .string(message)]))
        }
        do {
            let data = try JSONEncoder().encode(command) + Data([10])
            let actionID = command.actionID
            if let error = stdin.enqueue(data, failure: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let actionID { self.session.receiveError(replyTo: actionID, message: message) }
                    self.apply(IPCEvent(kind: .error, eventName: "error", fields: ["message": .string(message)]))
                }
            }) { report(error) }
        } catch { report(error.localizedDescription) }
    }

    func stop() async {
        guard let process else { session.clearPendingCommands(); status = .stopped; return }
        ProcessStop.schedule(process)
        send(.stop())
        let deadline = Date().addingTimeInterval(Limits.stopWaitSeconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        session.clearPendingCommands()
        status = .stopped
    }

    func stopSynchronously() {
        session.clearPendingCommands()
        guard let process, process.isRunning else { return }
        ProcessStop.schedule(process)
        send(.stop())
        let deadline = Date().addingTimeInterval(Limits.stopWaitSeconds)
        while process.isRunning && Date() < deadline { usleep(Limits.exitPollMicroseconds) }
    }

    private func didExit(code: Int32) {
        stdin?.close()
        stdin = nil
        outputReader = nil
        process = nil
        session.clearPendingCommands()
        if code == 0 { status = .stopped }
        else if case .error = status { }
        else { status = .error(lastFatalError ?? stderrLines.last ?? "Process exited with status \(code)") }
    }
}
