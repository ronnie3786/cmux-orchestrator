import Foundation

/// A lossless JSON value used at the Pi protocol boundary.
///
/// Pi extensions can add fields to messages, tools, and interactions. Keeping
/// the wire value intact lets the native projection understand known fields
/// without making a newer extension unreadable by an older app.
enum PiJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PiJSONValue])
    case array([PiJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: PiJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([PiJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension PiJSONValue {
    var objectValue: [String: PiJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [PiJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case let .string(value): value
        case let .number(value):
            value.rounded() == value ? String(Int64(value)) : String(value)
        case let .bool(value): String(value)
        case .object, .array, .null: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .string(value): Bool(value)
        case .number, .object, .array, .null: nil
        }
    }

    subscript(_ key: String) -> PiJSONValue? {
        objectValue?[key]
    }

    func value(for keys: String...) -> PiJSONValue? {
        guard let objectValue else { return nil }
        for key in keys where objectValue[key] != nil {
            return objectValue[key]
        }
        return nil
    }

    func string(for keys: String...) -> String? {
        guard let objectValue else { return nil }
        for key in keys {
            if let value = objectValue[key]?.stringValue { return value }
        }
        return nil
    }

    func bool(for keys: String...) -> Bool? {
        guard let objectValue else { return nil }
        for key in keys {
            if let value = objectValue[key]?.boolValue { return value }
        }
        return nil
    }

    func number(for keys: String...) -> Double? {
        guard let objectValue else { return nil }
        for key in keys {
            if case let .number(value)? = objectValue[key] { return value }
        }
        return nil
    }

    var displayString: String {
        switch self {
        case let .string(value):
            value
        case let .number(value):
            value.rounded() == value ? String(Int64(value)) : String(value)
        case let .bool(value):
            String(value)
        case .null:
            "null"
        case .array, .object:
            (try? String(data: JSONEncoder.piPretty.encode(self), encoding: .utf8)) ?? ""
        }
    }
}

private extension JSONEncoder {
    static let piPretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
