import Foundation

nonisolated struct DeviceSummary: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let path: String
    let valid: Bool
    let error: String?
}
