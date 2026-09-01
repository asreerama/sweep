import Foundation

/// Strict decoding helpers. Unknown fields and unknown enum values are hard failures:
/// a catalog authored against a newer schema must not silently lose meaning here.
enum RuleCatalogDecoding {

    /// Coding key that accepts anything, used to see the keys Codable would otherwise drop.
    struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    static func rejectUnknownKeys(in decoder: any Decoder, known: Set<String>, container: String) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        for key in raw.allKeys where !known.contains(key.stringValue) {
            throw RuleCatalogError.unknownField(container: container, field: key.stringValue)
        }
    }

    static func decodeEnum<T: RawRepresentable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        key: K,
        ruleID: String?
    ) throws -> T where T.RawValue == String {
        let raw = try container.decode(String.self, forKey: key)
        guard let value = T(rawValue: raw) else {
            throw RuleCatalogError.unknownValue(ruleID: ruleID, field: key.stringValue, value: raw)
        }
        return value
    }

    static func decodeOptionalEnum<T: RawRepresentable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        key: K,
        ruleID: String?
    ) throws -> T? where T.RawValue == String {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw RuleCatalogError.unknownValue(ruleID: ruleID, field: key.stringValue, value: raw)
        }
        return value
    }

    static func decodeEnumArray<T: RawRepresentable, K: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<K>,
        key: K,
        ruleID: String?
    ) throws -> [T] where T.RawValue == String {
        let raws = try container.decode([String].self, forKey: key)
        return try raws.map { raw in
            guard let value = T(rawValue: raw) else {
                throw RuleCatalogError.unknownValue(ruleID: ruleID, field: key.stringValue, value: raw)
            }
            return value
        }
    }

    /// Codable's own errors carry no rule context; map them onto the catalog vocabulary.
    static func translate(_ error: any Error) -> RuleCatalogError {
        if let catalogError = error as? RuleCatalogError { return catalogError }
        guard let decodingError = error as? DecodingError else {
            return .malformedJSON(String(describing: error))
        }
        switch decodingError {
        case .keyNotFound(let key, _):
            return .missingField(ruleID: nil, field: key.stringValue)
        case .typeMismatch(let type, let context):
            return .malformedJSON("expected \(type) at \(path(context)): \(context.debugDescription)")
        case .valueNotFound(let type, let context):
            return .malformedJSON("null where \(type) required at \(path(context))")
        case .dataCorrupted(let context):
            return .malformedJSON("\(context.debugDescription) at \(path(context))")
        @unknown default:
            return .malformedJSON(String(describing: decodingError))
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.isEmpty ? "<root>" : context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

/// Reads and validates a rule catalog. The only supported way to obtain a ``RuleCatalog``
/// from untrusted bytes.
public enum RuleCatalogLoader {

    public static func load(data: Data) throws -> RuleCatalog {
        do {
            return try JSONDecoder().decode(RuleCatalog.self, from: data)
        } catch {
            throw RuleCatalogDecoding.translate(error)
        }
    }

    public static func load(contentsOf url: URL) throws -> RuleCatalog {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RuleCatalogError.unreadable(url: url, reason: error.localizedDescription)
        }
        return try load(data: data)
    }
}
