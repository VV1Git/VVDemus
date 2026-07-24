import Foundation

/// Minimal nil-propagating navigator over `JSONSerialization` output, for walking
/// YouTube's deeply nested (and semi-undocumented) InnerTube responses without a
/// mountain of Codable types for structure that changes shelf-to-shelf.
struct JSON {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    subscript(key: String) -> JSON {
        JSON((value as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = value as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    var string: String? { value as? String }
    var int: Int? { value as? Int }
    var array: [JSON]? { (value as? [Any])?.map(JSON.init) }
    var exists: Bool { value != nil }

    static func parse(_ data: Data) throws -> JSON {
        JSON(try JSONSerialization.jsonObject(with: data))
    }
}
