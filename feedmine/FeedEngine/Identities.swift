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
/// Computed as a positive 63-bit digest of `SourceKey`. The hash algorithm
/// and canonicalization version are explicit catalog metadata. A collision
/// with a different key fails validation rather than silently merging sources.
struct SourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: Int64

    init(rawValue: Int64) {
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
/// Computed as a positive 63-bit digest of `NodeKey`. Same collision
/// validation rules apply as SourceID.
struct CatalogNodeID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: Int64

    init(rawValue: Int64) {
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
enum CatalogNodeKind: Int, Codable, Sendable, CaseIterable {
    case topic = 0
    case country = 1
    case region = 2
    case subcategory = 3
}
