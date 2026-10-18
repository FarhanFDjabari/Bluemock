import Foundation

nonisolated struct CLILocation: Sendable {
    let executable: URL
    let version: String
    let loginPath: String
}

enum CLILocator {
    static let overrideKey = "BluemockCLIPath"
    static let transportKey = "BluemockTransport"
    private static var cachedLoginInfo: (path: String, command: String?)?

    static func locate() async -> CLILocation? {
        let shell = await loginShellInfo()
        let path = shell.path.isEmpty ? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin" : shell.path
        var candidates: [URL] = []
        if let override = UserDefaults.standard.string(forKey: overrideKey), !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        if let command = shell.command, !command.isEmpty {
            candidates.append(URL(fileURLWithPath: (command as NSString).expandingTildeInPath))
        }
        candidates += ["~/.local/bin/bluemock", "/opt/homebrew/bin/bluemock", "/usr/local/bin/bluemock"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            if let result = try? await CLIRunner.run(executable: candidate, args: ["--version"], timeout: 5, path: path),
               result.exitCode == 0 {
                let version = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                return CLILocation(executable: candidate, version: version, loginPath: path)
            }
        }
        return nil
    }

    private static func loginShellInfo() async -> (path: String, command: String?) {
        if let cachedLoginInfo { return cachedLoginInfo }
        let result = try? await CLIRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            args: ["-lc", "printf '__BLUEMOCK_PATH__=%s\\n' \"$PATH\"; printf '__BLUEMOCK_CLI__=%s\\n' \"$(command -v bluemock)\""],
            timeout: 5)
        let lines = (result?.stdoutText ?? "").split(whereSeparator: \.isNewline).map(String.init)
        let path = lines.first(where: { $0.hasPrefix("__BLUEMOCK_PATH__=") })
            .map { String($0.dropFirst("__BLUEMOCK_PATH__=".count)) }
            ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let command = lines.first(where: { $0.hasPrefix("__BLUEMOCK_CLI__=") })
            .map { String($0.dropFirst("__BLUEMOCK_CLI__=".count)) }
        let info = (path: path, command: command?.isEmpty == false ? command : nil)
        cachedLoginInfo = info
        return info
    }
}
