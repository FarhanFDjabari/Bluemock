import Foundation
import Darwin

/// Only the serial queue touches the blocking pipe; admission is byte bounded.
nonisolated final class DeviceInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bluemock.stdin")
    private let lock = NSLock()
    private var pendingBytes = 0
    private var closed = false
    private let handle: FileHandle

    init(_ handle: FileHandle) { self.handle = handle }

    func enqueue(_ data: Data, failure: @escaping @Sendable (String) -> Void) -> String? {
        guard data.count <= Limits.maxCommandBytes else { return "Command exceeds the 256 KiB limit." }
        lock.lock()
        guard !closed, pendingBytes + data.count <= Limits.maxPendingStdinBytes else {
            lock.unlock()
            return "Device input is busy; pending commands exceed the 1 MiB limit."
        }
        pendingBytes += data.count
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pendingBytes -= data.count; lock.unlock() }
            lock.lock(); let shouldWrite = !closed; lock.unlock()
            guard shouldWrite else { return }
            do { try handle.write(contentsOf: data) }
            catch { failure("Could not send command: \(error.localizedDescription)") }
        }
        return nil
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
        queue.async { [self] in try? handle.close() }
    }
}

nonisolated enum ProcessStop {
    static func schedule(_ child: Process) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Limits.stopGraceSeconds) {
            if child.isRunning { kill(child.processIdentifier, SIGTERM) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Limits.stopKillSeconds) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}
