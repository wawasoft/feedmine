import Foundation
import SwiftUI

/// Produces attributed and plain-text share strings for feed items.
/// Rich format: bold title + excerpt + "Read on Feedmine" with deep link.
/// Plain format: same structure, for UIActivityViewController fallback.
struct RichShareFormatter: Sendable {

    /// Attributed string suitable for ShareLink or rich Messages/Mail.
    /// Title is bold, excerpt in secondary style, deep link in accent color.
    @MainActor
    static func attributedString(for item: FeedItem) -> AttributedString {
        var str = AttributedString("\(item.title)\n")
        str.font = .headline

        var spacer = AttributedString("\n")
        spacer.font = .caption2
        str += spacer

        var excerpt = AttributedString("\(item.excerpt)\n")
        excerpt.foregroundColor = .secondary
        excerpt.font = .subheadline
        str += excerpt

        var spacer2 = AttributedString("\n")
        spacer2.font = .caption2
        str += spacer2

        var via = AttributedString("Read on Feedmine: feedmine://article/\(item.id)")
        via.foregroundColor = .accentColor
        via.font = .caption
        str += via

        return str
    }

    /// Plain text fallback for UIActivityViewController and apps that
    /// don't support AttributedString sharing.
    static func plainText(for item: FeedItem) -> String {
        """
        \(item.title)

        \(item.excerpt)

        Read on Feedmine: \(item.url)
        """
    }
}
