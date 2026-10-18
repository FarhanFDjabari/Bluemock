import Foundation

nonisolated struct WellKnownUUID: Identifiable, Equatable, Sendable {
    let name: String
    let uuid: String
    var id: String { uuid + name }
}

nonisolated enum WellKnownUUIDs {
    static let services: [WellKnownUUID] = [
        .init(name: "HM-10 Serial", uuid: "FFE0"),
        .init(name: "Nordic UART", uuid: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        .init(name: "Heart Rate", uuid: "180D"),
        .init(name: "Battery", uuid: "180F"),
        .init(name: "Device Information", uuid: "180A"),
        .init(name: "Lematec Gauge", uuid: "FFF0"),
        .init(name: "Shahe Gauge", uuid: "FFFF")
    ]

    static let characteristics: [WellKnownUUID] = [
        .init(name: "HM-10 Serial", uuid: "FFE1"),
        .init(name: "Nordic UART RX", uuid: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
        .init(name: "Nordic UART TX", uuid: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
        .init(name: "Heart Rate Measurement", uuid: "2A37"),
        .init(name: "Body Sensor Location", uuid: "2A38"),
        .init(name: "Battery Level", uuid: "2A19"),
        .init(name: "Lematec Gauge", uuid: "FFF1"),
        .init(name: "Shahe Gauge", uuid: "FF00")
    ]

    static func isValid(_ value: String) -> Bool {
        value.range(of: #"^(?:[0-9A-Fa-f]{4}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{32}|[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})$"#, options: .regularExpression) != nil
    }
}
