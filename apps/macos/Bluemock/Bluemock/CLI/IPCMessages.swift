import Foundation

nonisolated enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
}

nonisolated struct IPCEvent: Codable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case ready, advertising, connected, disconnected, subscribed, rx, tx, state, log, error, stopped
        case unknown
    }
    let kind: Kind
    let eventName: String
    let fields: [String: JSONValue]
    var sequence = 0

    private enum CodingKeys: String, CodingKey { case event }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let raw = try container.decode(String.self, forKey: DynamicCodingKey("event"))
        eventName = raw
        kind = Kind(rawValue: raw) ?? .unknown
        var decoded: [String: JSONValue] = [:]
        for key in container.allKeys where key.stringValue != "event" {
            decoded[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        fields = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(eventName, forKey: DynamicCodingKey("event"))
        for (key, value) in fields {
            try container.encode(value, forKey: DynamicCodingKey(key))
        }
    }
}

private nonisolated struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct IPCCommand: Encodable, Sendable {
    let cmd: String
    var id: String?
    var actionID: String?
    var params: [String: JSONValue]?
    var characteristic: String?
    var text: String?
    var hex: String?
    var bytes: [JSONValue]?
    var values: [String: JSONValue]?

    enum CodingKeys: String, CodingKey { case cmd, id, params, characteristic, text, hex, bytes, values }

    static func action(_ id: String, params: [String: JSONValue] = [:]) -> Self {
        Self(cmd: "action", actionID: id, params: params)
    }
    static func state() -> Self { Self(cmd: "state") }
    static func drop() -> Self { Self(cmd: "drop") }
    static func stop() -> Self { Self(cmd: "stop") }
    static func set(_ values: [String: JSONValue]) -> Self { Self(cmd: "set", values: values) }
    static func send(_ characteristic: String, text: String) -> Self {
        Self(cmd: "send", characteristic: characteristic, text: text)
    }
    static func send(_ characteristic: String, hex: String) -> Self {
        Self(cmd: "send", characteristic: characteristic, hex: hex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cmd, forKey: .cmd)
        try container.encodeIfPresent(actionID ?? id, forKey: .id)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(characteristic, forKey: .characteristic)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(hex, forKey: .hex)
        try container.encodeIfPresent(bytes, forKey: .bytes)
        try container.encodeIfPresent(values, forKey: .values)
    }
}
