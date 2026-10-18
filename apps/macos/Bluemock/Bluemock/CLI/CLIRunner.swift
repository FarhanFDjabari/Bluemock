import Foundation
import Darwin

private nonisolated final class ProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private var outputEnded = false
    private var errorEnded = false
    private var exitCode: Int32?
    private var finished = false
    private var completion: ((Result<CLIRunner.Result, Error>) -> Void)?

    init(completion: @escaping (Result<CLIRunner.Result, Error>) -> Void) { self.completion = completion }
    func append(_ data: Data, toOutput: Bool) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return true }
        let count = toOutput ? output.count : error.count
        guard data.count <= Limits.maxCaptureBytes - count else { lock.unlock(); return false }
        if toOutput { output.append(data) } else { error.append(data) }
        lock.unlock()
        return true
    }
    func end(output streamIsOutput: Bool) {
        lock.lock()
        if streamIsOutput { outputEnded = true } else { errorEnded = true }
        lock.unlock()
        finishIfReady()
    }
    func terminated(_ code: Int32) {
        lock.lock(); exitCode = code; lock.unlock()
        finishIfReady()
    }
    private func finishIfReady() {
        lock.lock()
        guard !finished, let code = exitCode, outputEnded, errorEnded else { lock.unlock(); return }
        finished = true
        let callback = completion
        completion = nil
        let out = output, err = error
        lock.unlock()
        callback?(.success(CLIRunner.Result(exitCode: code, stdout: out, stderr: err)))
    }
    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(.failure(error))
    }
}

enum CLIRunner {
    nonisolated struct Paths: Decodable, Sendable { let device_dir: String; let preset_dir: String; let version: String }
    nonisolated struct Preset: Decodable, Identifiable, Sendable { let id: String; let name: String; let description: String }
    nonisolated struct ValidationResponse: Decodable, Sendable { let ok: Bool; let errors: [EditorValidationIssue] }
    nonisolated struct Result: Sendable {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    nonisolated static func run(executable: URL, args: [String], stdin: Data? = nil,
                                timeout: TimeInterval = 30, path: String? = nil) async throws -> Result {
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = args
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        process.environment = environment

        return try await withCheckedThrowingContinuation { continuation in
            let capture = ProcessCapture { result in
                continuation.resume(with: result)
            }
            func configure(_ handle: FileHandle, output: Bool) {
                handle.readabilityHandler = { file in
                    let data = file.availableData
                    if data.isEmpty {
                        file.readabilityHandler = nil
                        capture.end(output: output)
                    } else {
                        if !capture.append(data, toOutput: output) {
                            capture.fail(CLIRunnerError.commandFailed("CLI output exceeds the 8 MiB per-stream limit."))
                            ProcessStop.schedule(process)
                            if process.isRunning { kill(process.processIdentifier, SIGTERM) }
                        }
                    }
                }
            }
            configure(output.fileHandleForReading, output: true)
            configure(errors.fileHandleForReading, output: false)
            process.terminationHandler = { child in capture.terminated(child.terminationStatus) }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + Limits.captureKillSeconds) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                if let stdin {
                    try input.fileHandleForWriting.write(contentsOf: stdin)
                }
                try? input.fileHandleForWriting.close()
            } catch {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + Limits.captureKillSeconds) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                capture.fail(error)
                return
            }
        }
    }

    nonisolated static func json<T: Decodable>(_ type: T.Type, executable: URL, args: [String],
                                                path: String? = nil) async throws -> T {
        let result = try await run(executable: executable, args: args, path: path)
        guard result.exitCode == 0 else {
            throw CLIRunnerError.commandFailed(result.stderrText.isEmpty ? result.stdoutText : result.stderrText)
        }
        return try JSONDecoder().decode(type, from: result.stdout)
    }

    nonisolated static func paths(using cli: CLILocation) async throws -> Paths {
        try await json(Paths.self, executable: cli.executable, args: ["paths", "--json"], path: cli.loginPath)
    }
    nonisolated static func devicesList(using cli: CLILocation) async throws -> [DeviceSummary] {
        try await json([DeviceSummary].self, executable: cli.executable, args: ["devices", "list", "--json"], path: cli.loginPath)
    }
    nonisolated static func presetsList(using cli: CLILocation) async throws -> [Preset] {
        try await json([Preset].self, executable: cli.executable, args: ["presets", "list", "--json"], path: cli.loginPath)
    }
    nonisolated static func presetsCopy(_ id: String, using cli: CLILocation) async throws -> Result {
        let result = try await run(executable: cli.executable, args: ["presets", "copy", id], path: cli.loginPath)
        guard result.exitCode == 0 else { throw CLIRunnerError.commandFailed(result.stderrText) }
        return result
    }
    nonisolated static func show(_ source: String, using cli: CLILocation) async throws -> DeviceDefinition {
        try await json(DeviceDefinition.self, executable: cli.executable,
                       args: ["show", source, "--json"], path: cli.loginPath)
    }

    nonisolated static func show(_ source: String, cli: CLILocation) async throws -> DeviceDefinition {
        try await show(source, using: cli)
    }

    nonisolated static func save(_ definition: DeviceDefinition, to path: String,
                                 using cli: CLILocation) async throws -> [EditorValidationIssue] {
        let data = try jsonData(definition)
        let isJSON = URL(fileURLWithPath: path).pathExtension.lowercased() == "json"
        if isJSON {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bluemock-editor-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            let issues = try await validate(temporary.path, using: cli)
            guard issues.isEmpty else { return issues }
            let destination = URL(fileURLWithPath: path).standardizedFileURL
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return []
        }
        if !definition.unknownTopLevel.isEmpty || definition.hasUnknownTestFields {
            return [EditorValidationIssue(path: "$", message: "The CLI YAML normalizer cannot preserve unknown top-level or test fields. Keep this definition as JSON or remove those fields.")]
        }
        let result = try await run(executable: cli.executable, args: ["save", path, "--json-errors"],
                                   stdin: data, path: cli.loginPath)
        if result.exitCode == 0 { return [] }
        if let response = try? JSONDecoder().decode(ValidationResponse.self, from: result.stdout) { return response.errors }
        return [EditorValidationIssue(path: "$", message: result.stderrText.isEmpty ? result.stdoutText : result.stderrText)]
    }

    nonisolated private static func jsonData(_ definition: DeviceDefinition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(definition)
    }
    nonisolated static func validate(_ path: String, using cli: CLILocation) async throws -> [EditorValidationIssue] {
        let result = try await run(executable: cli.executable,
                                   args: ["validate", path, "--json"], path: cli.loginPath)
        if let report = try? JSONDecoder().decode(ValidationResponse.self, from: result.stdout) {
            return report.errors
        }
        return [EditorValidationIssue(path: "$", message: result.stderrText.isEmpty ? result.stdoutText : result.stderrText)]
    }
    nonisolated static func validate(_ definition: DeviceDefinition, using cli: CLILocation) async throws -> [EditorValidationIssue] {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bluemock-editor-\(UUID().uuidString).json")
        let data = try jsonData(definition)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        return try await validate(temporary.path, using: cli)
    }
    nonisolated static func doctor(using cli: CLILocation, fix: Bool = false) async throws -> DoctorReport {
        try await json(DoctorReport.self, executable: cli.executable,
                       args: ["doctor", "--json"] + (fix ? ["--fix"] : []), path: cli.loginPath)
    }
}

nonisolated enum CLIRunnerError: LocalizedError {
    case commandFailed(String)
    var errorDescription: String? {
        switch self { case .commandFailed(let message): return message.isEmpty ? "CLI command failed" : message }
    }
}
