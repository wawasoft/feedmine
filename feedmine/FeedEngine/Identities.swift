import Foundation

// MARK: - FeedEngine Identities
//
// Stable identity types for the FeedEngine catalog.
// SourceID and CatalogNodeID are deterministic across catalog rebuilds —
// they are NOT SQLite auto-increment row IDs.

/// Stable semantic identity for a feed source, used to reconstruct the
/// same SourceID across catalog rebuilds.
///
/// Derived from a versioned conservative canonical form of the declared
/// feed URL. The canonicalization version is explicit catalog metadata.
struct SourceKey: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// Compact numeric identity for a feed source.
///
/// The compiler derives this from `SourceKey` and validates collisions before
/// publishing a catalog. The UI only carries this compact value.
struct SourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var description: String { String(rawValue) }
}

/// Stable semantic identity for a catalog taxonomy node, derived from the
/// editorial path (directory hierarchy + OPML outline nesting).
struct NodeKey: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

/// Compact numeric identity for a catalog taxonomy node.
///
/// Derived from `NodeKey` by the compiler. `0` is reserved for the root.
struct CatalogNodeID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var description: String { String(rawValue) }
}

/// Sentinel for "no source" — SourceID(0). Never produced by the compiler.
extension SourceID {
    static let none = SourceID(rawValue: 0)
}

/// Sentinel for "no node" / root — CatalogNodeID(0).
extension CatalogNodeID {
    static let none = CatalogNodeID(rawValue: 0)
    static let root = CatalogNodeID(rawValue: 0)
}

/// The kind of a catalog taxonomy node.
enum CatalogNodeKind: Int, Codable, Sendable, CaseIterable, Equatable {
    case topic = 0
    case country = 1
    case region = 2
    case subcategory = 3
    case language = 4
}
