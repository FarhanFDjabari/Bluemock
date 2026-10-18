import Foundation

nonisolated struct EditorValidationIssue: Codable, Identifiable, Sendable {
    let path: String
    let message: String
    var id: String { path + ":" + message }
}

nonisolated struct EditorValidationResult: Decodable, Sendable {
    let ok: Bool
    let errors: [EditorValidationIssue]
}
