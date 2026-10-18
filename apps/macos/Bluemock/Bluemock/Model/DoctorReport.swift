import Foundation

nonisolated struct DoctorCheck: Codable, Identifiable, Sendable {
    let id: String
    let ok: Bool
    let detail: String
    let fix: String?
}

nonisolated struct DoctorReport: Codable, Sendable {
    let ok: Bool
    let checks: [DoctorCheck]

    var summary: String {
        guard ok else { return checks.first(where: { !$0.ok })?.detail ?? "Environment check failed" }
        let apiCheck = checks.first(where: { $0.id.hasPrefix("api:") })
        let btCheck = apiCheck.flatMap { api in
            let serial = String(api.id.dropFirst("api:".count))
            return checks.first(where: { $0.id == "bluetooth:" + serial })
        }
        if let apiCheck, let btCheck,
           let apiRange = apiCheck.detail.range(of: "API "),
           let api = apiCheck.detail[apiRange.upperBound...].split(separator: " ").first {
            let avd = apiCheck.detail.components(separatedBy: " · API").first ?? apiCheck.detail
            return "\(avd) · API \(api) · \(btCheck.ok ? "BT on" : "BT off")"
        }
        if let apiCheck { return apiCheck.detail + (btCheck.map { " · \($0.ok ? "BT on" : "BT off")" } ?? "") }
        return checks.first(where: { $0.id == "devices" })?.detail ?? "Environment ready"
    }

    var hasFixableFailure: Bool { checks.contains { !$0.ok && $0.fix != nil } }
}
