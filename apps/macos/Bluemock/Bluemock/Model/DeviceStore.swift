import Foundation
import Observation
import Darwin

@MainActor @Observable
final class DeviceStore {
    static let shared = DeviceStore()
    private(set) var cli: CLILocation?
    private(set) var deviceDirectory: URL?
    private(set) var devices: [DeviceSummary] = []
    private(set) var presets: [CLIRunner.Preset] = []
    private(set) var doctorReport: DoctorReport?
    private(set) var processes: [String: DeviceProcess] = [:]
    private(set) var restartRequired = Set<String>()
    @ObservationIgnored private var sessions: [String: DeviceSession] = [:]
    private(set) var loadError: String?
    private(set) var loading = false

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watcherFD: Int32 = -1
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var lastDoctorRefresh: Date?
    @ObservationIgnored private var didStartAutostart = false
    @ObservationIgnored private var hasLoadedDevices = false

    private init() {}
    var hasRunningDevice: Bool { processes.values.contains { $0.isRunning } }
    var installCommand: String { "scripts/install.sh" }
    var transportOverride: String? {
        let value = UserDefaults.standard.string(forKey: CLILocator.transportKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func refresh(forceDoctor: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        cli = await CLILocator.locate()
        guard let cli else { loadError = "Bluemock CLI not found"; return }
        do {
            let paths = try await CLIRunner.paths(using: cli)
            let directory = URL(fileURLWithPath: paths.device_dir, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            deviceDirectory = directory
            async let rows = CLIRunner.devicesList(using: cli)
            async let available = CLIRunner.presetsList(using: cli)
            devices = try await rows
            presets = (try? await available) ?? presets
            syncProcesses()
            installWatcher(directory)
            await refreshDoctor(force: forceDoctor)
            loadError = nil
            hasLoadedDevices = true
        } catch { loadError = error.localizedDescription; hasLoadedDevices = true }
    }

    func startAutostartIfNeeded() async {
        guard !didStartAutostart else { return }
        while loading { try? await Task.sleep(for: .milliseconds(50)) }
        if !hasLoadedDevices { await refresh() }
        while loading { try? await Task.sleep(for: .milliseconds(50)) }
        guard !didStartAutostart else { return }
        didStartAutostart = true
        // UserDefaults argument domain supports `-BluemockAutostart <device-id>` for headless smoke tests and scripts.
        if let id = UserDefaults.standard.string(forKey: "BluemockAutostart"),
           devices.contains(where: { $0.id == id && $0.valid }) {
            start(id)
        }
    }

    func refreshDoctor(force: Bool = false) async {
        guard let cli else { return }
        if !force, let lastDoctorRefresh, Date().timeIntervalSince(lastDoctorRefresh) < 30 { return }
        lastDoctorRefresh = Date()
        doctorReport = try? await CLIRunner.doctor(using: cli)
    }

    func fixDoctor() async {
        guard let cli else { return }
        doctorReport = try? await CLIRunner.doctor(using: cli, fix: true)
        lastDoctorRefresh = Date()
    }

    func copyPreset(_ id: String) async {
        guard let cli else { return }
        do {
            _ = try await CLIRunner.presetsCopy(id, using: cli)
            await reloadDevices()
        } catch { loadError = error.localizedDescription }
    }

    func start(_ id: String) {
        guard let cli, let row = devices.first(where: { $0.id == id }), row.valid else { return }
        if let existing = processes[id], existing.isRunning { return }
        let session = sessions[id] ?? DeviceSession()
        sessions[id] = session
        let child = DeviceProcess(summary: row, cli: cli, transport: transportOverride, session: session)
        processes[id] = child
        restartRequired.remove(id)
        child.start()
    }

    func markNeedsRestart(_ id: String, previousID: String? = nil) {
        if let previousID, previousID != id, let process = processes.removeValue(forKey: previousID) {
            processes[id] = process
            if let session = sessions.removeValue(forKey: previousID) { sessions[id] = session }
            if restartRequired.remove(previousID) != nil { restartRequired.insert(id) }
        }
        if processes[id]?.isRunning == true { restartRequired.insert(id) }
    }

    func restart(_ id: String) async {
        guard restartRequired.contains(id) else { return }
        await stop(id)
        restartRequired.remove(id)
        start(id)
    }

    func stop(_ id: String) async {
        guard let process = processes[id] else { return }
        await process.stop()
        process.session.clearPendingCommands()
    }

    func stopAll() async {
        for process in processes.values {
            await process.stop()
            process.session.clearPendingCommands()
        }
    }

    func stopAllSynchronously() {
        processes.values.forEach {
            $0.stopSynchronously()
            $0.session.clearPendingCommands()
        }
    }

    func reloadDevices() async {
        guard let cli else { return }
        do { devices = try await CLIRunner.devicesList(using: cli); syncProcesses() }
        catch { loadError = error.localizedDescription }
    }

    private func syncProcesses() {
        let finished = processes.filter { !$0.value.isRunning && $0.value.status == .stopped }.map(\.key)
        for id in finished {
            processes[id]?.session.clearPendingCommands()
            processes.removeValue(forKey: id)
        }
    }

    private func installWatcher(_ directory: URL) {
        guard watcher == nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watcherFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadTask?.cancel()
            self.reloadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                await self.reloadDevices()
            }
        }
        source.setCancelHandler { close(fd) }
        watcher = source
        source.resume()
    }

}
