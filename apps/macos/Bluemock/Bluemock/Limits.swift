import Foundation

nonisolated enum Limits {
    static let maxPendingStdinBytes = 1 * 1024 * 1024
    static let maxCommandBytes = 256 * 1024
    static let maxCaptureBytes = 8 * 1024 * 1024
    static let maxIPCLineBytes = 1 * 1024 * 1024
    static let maxStderrBytes = 64 * 1024
    static let maxPendingEventBatches = 64
    static let maxVisibleEvents = 200
    static let maxStderrLines = 8
    static let stopGraceSeconds = 0.5
    static let stopKillSeconds = 2.0
    static let stopWaitSeconds = 3.0
    static let captureKillSeconds = 1.0
    static let exitPollMicroseconds: useconds_t = 20_000
    static let reloadDebounce = Duration.milliseconds(300)
}
