import Foundation

nonisolated struct DeviceDefinition: Codable, Equatable, Identifiable, Sendable {
    var bluemock = 1
    var id = "new-device"
    var name = "New device"
    var description = ""
    var address: String?
    var advertising = AdvertisingDefinition()
    var services: [ServiceDefinition] = []
    var state: [String: JSONValue] = [:]
    var rules: [RuleDefinition] = []
    var actions: [ActionDefinition] = []
    var tests: JSONValue?
    var unknownTopLevel: [String: JSONValue] = [:]
    static func blank() -> DeviceDefinition { DeviceDefinition() }

    var hasUnknownTestFields: Bool {
        guard case .array(let cases)? = tests else { return false }
        let supported: Set<String> = ["name", "write", "action", "params", "expect"]
        return cases.contains { value in
            guard let fields = value.objectValue else { return false }
            return !Set(fields.keys).isSubset(of: supported)
        }
    }

    init() {}

    private static let keys: Set<String> = ["bluemock", "id", "name", "description", "address", "advertising", "services", "state", "rules", "actions", "tests"]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DefinitionCodingKey.self)
        bluemock = try container.decodeIfPresent(Int.self, forKey: .init("bluemock")) ?? 1
        id = try container.decodeIfPresent(String.self, forKey: .init("id")) ?? "new-device"
        name = try container.decodeIfPresent(String.self, forKey: .init("name")) ?? "New device"
        description = try container.decodeIfPresent(String.self, forKey: .init("description")) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .init("address"))
        services = try container.decodeIfPresent([ServiceDefinition].self, forKey: .init("services")) ?? []
        if let ad = try container.decodeIfPresent(AdvertisingDefinition.self, forKey: .init("advertising")) {
            advertising = ad
            let adContainer = try container.nestedContainer(keyedBy: AdvertisingCodingKey.self, forKey: .init("advertising"))
            if !adContainer.contains(.service_uuids) {
                advertising.serviceUUIDs = services.filter(\.primary).map(\.uuid)
                advertising.followsPrimaryServices = true
            } else {
                advertising.followsPrimaryServices = advertising.serviceUUIDs == services.filter(\.primary).map(\.uuid)
            }
        } else {
            advertising = AdvertisingDefinition(serviceUUIDs: services.filter(\.primary).map(\.uuid))
        }
        state = try container.decodeIfPresent([String: JSONValue].self, forKey: .init("state")) ?? [:]
        rules = try container.decodeIfPresent([RuleDefinition].self, forKey: .init("rules")) ?? []
        actions = try container.decodeIfPresent([ActionDefinition].self, forKey: .init("actions")) ?? []
        tests = try container.decodeIfPresent(JSONValue.self, forKey: .init("tests"))
        unknownTopLevel = [:]
        for key in container.allKeys where !Self.keys.contains(key.stringValue) {
            unknownTopLevel[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DefinitionCodingKey.self)
        try container.encode(bluemock, forKey: .init("bluemock"))
        try container.encode(id, forKey: .init("id"))
        try container.encode(name, forKey: .init("name"))
        if !description.isEmpty { try container.encode(description, forKey: .init("description")) }
        try container.encodeIfPresent(address, forKey: .init("address"))
        try container.encode(advertising, forKey: .init("advertising"))
        try container.encode(services, forKey: .init("services"))
        if !state.isEmpty { try container.encode(state, forKey: .init("state")) }
        if !rules.isEmpty { try container.encode(rules, forKey: .init("rules")) }
        if !actions.isEmpty { try container.encode(actions, forKey: .init("actions")) }
        try container.encodeIfPresent(tests, forKey: .init("tests"))
        for (key, value) in unknownTopLevel where !Self.keys.contains(key) {
            try container.encode(value, forKey: .init(key))
        }
    }
}

nonisolated struct AdvertisingDefinition: Codable, Equatable, Sendable {
    var interval_ms = 250.0
    var service_uuids: [String] = []
    var manufacturer_data: ManufacturerDataDefinition?
    var followsPrimaryServices = true
    var serviceUUIDs: [String] {
        get { service_uuids }
        set { service_uuids = newValue }
    }
    private enum CodingKeys: String, CodingKey { case interval_ms, service_uuids, manufacturer_data }
    init(interval_ms: Double = 250, serviceUUIDs: [String] = [], manufacturerData: ManufacturerDataDefinition? = nil) {
        self.interval_ms = interval_ms
        service_uuids = serviceUUIDs
        manufacturer_data = manufacturerData
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval_ms = try c.decodeIfPresent(Double.self, forKey: .interval_ms) ?? 250
        service_uuids = try c.decodeIfPresent([String].self, forKey: .service_uuids) ?? []
        manufacturer_data = try c.decodeIfPresent(ManufacturerDataDefinition.self, forKey: .manufacturer_data)
        followsPrimaryServices = !c.contains(.service_uuids)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(interval_ms, forKey: .interval_ms)
        try c.encode(service_uuids, forKey: .service_uuids)
        try c.encodeIfPresent(manufacturer_data, forKey: .manufacturer_data)
    }
}

nonisolated struct ManufacturerDataDefinition: Codable, Equatable, Sendable { var company_id: Int; var hex: String }

nonisolated struct ServiceDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var uuid: String
    var primary = true
    var characteristics: [CharacteristicDefinition] = []
    private enum CodingKeys: String, CodingKey { case uuid, primary, characteristics }
    init(uuid: String = "180F", primary: Bool = true, characteristics: [CharacteristicDefinition] = []) {
        self.uuid = uuid; self.primary = primary; self.characteristics = characteristics
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        primary = try c.decodeIfPresent(Bool.self, forKey: .primary) ?? true
        characteristics = try c.decodeIfPresent([CharacteristicDefinition].self, forKey: .characteristics) ?? []
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        if !primary { try c.encode(false, forKey: .primary) }
        try c.encode(characteristics, forKey: .characteristics)
    }
}

nonisolated struct CharacteristicDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var characteristicID: String
    var uuid: String
    var properties: [String]
    var initial: PayloadDefinition?
    var encoding = "text"
    private enum CodingKeys: String, CodingKey { case characteristicID = "id", uuid, properties, initial, encoding }
    init(characteristicID: String = "level", uuid: String = "2A19", properties: [String] = ["read", "notify"], initial: PayloadDefinition? = nil, encoding: String = "text") {
        self.characteristicID = characteristicID; self.uuid = uuid; self.properties = properties; self.initial = initial; self.encoding = encoding
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        characteristicID = try c.decode(String.self, forKey: .characteristicID)
        uuid = try c.decode(String.self, forKey: .uuid)
        properties = try c.decode([String].self, forKey: .properties)
        initial = try c.decodeIfPresent(PayloadDefinition.self, forKey: .initial)
        encoding = try c.decodeIfPresent(String.self, forKey: .encoding) ?? "text"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(characteristicID, forKey: .characteristicID); try c.encode(uuid, forKey: .uuid)
        try c.encode(properties, forKey: .properties); try c.encodeIfPresent(initial, forKey: .initial)
        if encoding != "text" { try c.encode(encoding, forKey: .encoding) }
    }
}

nonisolated struct PayloadDefinition: Codable, Equatable, Sendable {
    var characteristic: String?
    var content: PayloadContent
    init(characteristic: String? = nil, content: PayloadContent = .text("")) { self.characteristic = characteristic; self.content = content }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DefinitionCodingKey.self)
        characteristic = try c.decodeIfPresent(String.self, forKey: .init("characteristic"))
        if let value = try c.decodeIfPresent(String.self, forKey: .init("text")) { content = .text(value) }
        else if let value = try c.decodeIfPresent(String.self, forKey: .init("hex")) { content = .hex(value) }
        else { content = .bytes(try c.decode([PayloadSegment].self, forKey: .init("bytes"))) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DefinitionCodingKey.self)
        try c.encodeIfPresent(characteristic, forKey: .init("characteristic"))
        switch content {
        case .text(let value): try c.encode(value, forKey: .init("text"))
        case .hex(let value): try c.encode(value, forKey: .init("hex"))
        case .bytes(let values): try c.encode(values, forKey: .init("bytes"))
        }
    }
}

nonisolated enum PayloadContent: Equatable, Sendable { case text(String), hex(String), bytes([PayloadSegment]) }

nonisolated struct PayloadSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: String
    var value: JSONValue
    init(kind: String = "u8", value: JSONValue = .number(0)) { self.kind = kind; self.value = value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DefinitionCodingKey.self)
        guard let key = c.allKeys.first else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one segment key")) }
        kind = key.stringValue
        value = try c.decode(JSONValue.self, forKey: key)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DefinitionCodingKey.self)
        try c.encode(value, forKey: .init(kind))
    }
}

private nonisolated struct DefinitionCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private nonisolated enum AdvertisingCodingKey: String, CodingKey { case service_uuids }

nonisolated struct RuleDefinition: Codable, Equatable, Identifiable, Sendable {
    var uiID = UUID()
    var on_write = ""
    var equals: String?
    var regex: String?
    var any: Bool?
    var trim = true
    var reply: PayloadDefinition?
    var setValues: [String: JSONValue] = [:]
    var id: UUID { uiID }
    private enum CodingKeys: String, CodingKey { case on_write, equals, regex, any, trim, reply, setValues = "set" }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on_write = try c.decode(String.self, forKey: .on_write)
        equals = try c.decodeIfPresent(String.self, forKey: .equals)
        regex = try c.decodeIfPresent(String.self, forKey: .regex)
        any = try c.decodeIfPresent(Bool.self, forKey: .any)
        trim = try c.decodeIfPresent(Bool.self, forKey: .trim) ?? true
        reply = try c.decodeIfPresent(PayloadDefinition.self, forKey: .reply)
        setValues = try c.decodeIfPresent([String: JSONValue].self, forKey: .setValues) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(on_write, forKey: .on_write)
        try c.encodeIfPresent(equals, forKey: .equals); try c.encodeIfPresent(regex, forKey: .regex)
        try c.encodeIfPresent(any, forKey: .any)
        if !trim { try c.encode(false, forKey: .trim) }
        try c.encodeIfPresent(reply, forKey: .reply)
        if !setValues.isEmpty { try c.encode(setValues, forKey: .setValues) }
    }
}

nonisolated struct ActionDefinition: Codable, Equatable, Identifiable, Sendable {
    var id = "action"
    var label = "Action"
    var params: [ActionParameterDefinition] = []
    var setValues: [String: JSONValue] = [:]
    var send: PayloadDefinition?
    private enum CodingKeys: String, CodingKey { case id, label, params, setValues = "set", send }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
        params = try c.decodeIfPresent([ActionParameterDefinition].self, forKey: .params) ?? []
        setValues = try c.decodeIfPresent([String: JSONValue].self, forKey: .setValues) ?? [:]
        send = try c.decodeIfPresent(PayloadDefinition.self, forKey: .send)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(label, forKey: .label)
        if !params.isEmpty { try c.encode(params, forKey: .params) }
        if !setValues.isEmpty { try c.encode(setValues, forKey: .setValues) }
        try c.encodeIfPresent(send, forKey: .send)
    }
}

nonisolated struct ActionParameterDefinition: Codable, Equatable, Identifiable, Sendable {
    var uiID = UUID()
    var name = "value"
    var type = "number"
    var defaultValue: JSONValue?
    var minimum: Double?
    var maximum: Double?
    var choices: [JSONValue]?
    var id: UUID { uiID }
    private enum CodingKeys: String, CodingKey { case name, type, defaultValue = "default", minimum = "min", maximum = "max", choices }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name); type = try c.decode(String.self, forKey: .type)
        defaultValue = try c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        minimum = try c.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try c.decodeIfPresent(Double.self, forKey: .maximum)
        choices = try c.decodeIfPresent([JSONValue].self, forKey: .choices)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try c.encodeIfPresent(minimum, forKey: .minimum); try c.encodeIfPresent(maximum, forKey: .maximum)
        try c.encodeIfPresent(choices, forKey: .choices)
    }
}
