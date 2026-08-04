import Foundation

enum MediaKind: String, Codable, Sendable {
    case text
    case video
    case audio
    case forum
}

struct FeedSource: Codable, Identifiable, Sendable {
    /// Canonical identity derived from the fetch URL. Two FeedSources with
    /// equivalent URLs (different auth params, scheme, www, trailing slash)
    /// share the same identity. This mirrors SourceReference.id.
    var id: String { OPMLParser.normalizeURL(url) }
    let title: String
    let url: String
    let category: String
    let region: String  // "global" | "countries/brazil"
    let language: String?   // ISO 639-1 code, inherited from OPML <head> or <outline>
    let mediaKind: MediaKind
    /// Content-derived source metadata bundled in curated OPML 2.0 files.
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let qualityScore: Int?
    /// Dormant current-sensitive sources remain discoverable, but are not
    /// fetched until the user explicitly enables or selects them.
    let defaultEnabled: Bool
    /// Contact metadata extracted from curated OPML files: the email address,
    /// the contact's name, where the contact info was found (provenance), and
    /// what kind of contact it is (e.g. "author", "podcast-host").
    let contactEmail: String?
    let contactName: String?
    let contactSource: String?
    let contactType: String?

    /// YouTube RSS feeds follow this URL pattern — it's the standard endpoint.
    /// https://www.youtube.com/feeds/videos.xml?channel_id=...
    var isYouTube: Bool {
        url.contains("youtube.com/feeds")
    }

    /// Only text news/blog sources are "country feeds" that should be opt-in.
    /// YouTube and podcast sources keep their country tag for language/region
    /// filtering but are always globally available — their country association
    /// is a language overlay, not an enable/disable gate.
    /// Uses isYouTube / mediaKind.audio instead of just mediaKind because
    /// YouTube entries inside country OPMLs get mediaKind=.text (the parser
    /// only tags .video when the OPML *file name* contains "youtube").
    var isCountryFeed: Bool {
        region.hasPrefix("countries/") && !isYouTube && mediaKind != .audio
    }

    init(title: String, url: String, category: String, region: String = "global",
         mediaKind: MediaKind = .text, language: String? = nil,
         sourceDescription: String? = nil, tags: [String] = [],
         nature: String? = nil, activity: String? = nil,
         qualityScore: Int? = nil, defaultEnabled: Bool = true,
         contactEmail: String? = nil, contactName: String? = nil,
         contactSource: String? = nil, contactType: String? = nil) {
        self.title = title
        self.url = url
        self.category = category
        self.region = region
        self.mediaKind = mediaKind
        self.language = language
        self.sourceDescription = sourceDescription
        self.tags = tags
        self.nature = nature
        self.activity = activity
        self.qualityScore = qualityScore
        self.defaultEnabled = defaultEnabled
        self.contactEmail = contactEmail
        self.contactName = contactName
        self.contactSource = contactSource
        self.contactType = contactType
    }

    enum CodingKeys: String, CodingKey {
        case title, url, category, region, language, mediaKind = "media_kind"
        case sourceDescription = "source_description"
        case tags, nature, activity
        case qualityScore = "quality_score"
        case defaultEnabled = "default_enabled"
        case contactEmail = "contact_email"
        case contactName = "contact_name"
        case contactSource = "contact_source"
        case contactType = "contact_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        category = try c.decode(String.self, forKey: .category)
        region = (try? c.decode(String.self, forKey: .region)) ?? "global"
        language = try? c.decode(String.self, forKey: .language)
        mediaKind = (try? c.decode(MediaKind.self, forKey: .mediaKind)) ?? .text
        sourceDescription = try? c.decode(String.self, forKey: .sourceDescription)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        nature = try? c.decode(String.self, forKey: .nature)
        activity = try? c.decode(String.self, forKey: .activity)
        qualityScore = try? c.decode(Int.self, forKey: .qualityScore)
        defaultEnabled = (try? c.decode(Bool.self, forKey: .defaultEnabled)) ?? true
        contactEmail = try? c.decode(String.self, forKey: .contactEmail)
        contactName = try? c.decode(String.self, forKey: .contactName)
        contactSource = try? c.decode(String.self, forKey: .contactSource)
        contactType = try? c.decode(String.self, forKey: .contactType)
    }
}

/// Stable, presentation-ready identity for opening a single source.
///
/// The normalized feed URL is the durable key. OPML placement remains the
/// source's one editorial home; tags, formats, search results, and personal
/// collections only point at this identity and never duplicate the OPML row.
struct SourceReference: Identifiable, Equatable, Sendable {
    var id: String { OPMLParser.normalizeURL(feedURL) }

    let title: String
    let feedURL: String
    let siteURL: String?
    let displayHost: String?
    let category: String
    let region: String
    let mediaKind: MediaKind
    let language: String?
    let sourceDescription: String?
    let tags: [String]
    let nature: String?
    let activity: String?
    let qualityScore: Int?
    let defaultEnabled: Bool
    let contactEmail: String?
    let contactName: String?
    let contactSource: String?
    let contactType: String?

    init(
        title: String,
        feedURL: String,
        siteURL: String? = nil,
        displayHost: String? = nil,
        category: String = "Personal",
        region: String = "personal",
        mediaKind: MediaKind = .text,
        language: String? = nil,
        sourceDescription: String? = nil,
        tags: [String] = [],
        nature: String? = nil,
        activity: String? = nil,
        qualityScore: Int? = nil,
        defaultEnabled: Bool = true,
        contactEmail: String? = nil,
        contactName: String? = nil,
        contactSource: String? = nil,
        contactType: String? = nil
    ) {
        self.title = title
        // Preserve the fetch endpoint (including signed/authorization query
        // parameters). `id` and registry lookups derive a separate canonical
        // identity via OPMLParser.normalizeURL.
        self.feedURL = OPMLParser.requestURL(feedURL)
        self.siteURL = siteURL
        self.displayHost = displayHost ?? URL(string: feedURL)?.host
        self.category = category
        self.region = region
        self.mediaKind = mediaKind
        self.language = language
        self.sourceDescription = sourceDescription
        self.tags = tags
        self.nature = nature
        self.activity = activity
        self.qualityScore = qualityScore
        self.defaultEnabled = defaultEnabled
        self.contactEmail = contactEmail
        self.contactName = contactName
        self.contactSource = contactSource
        self.contactType = contactType
    }

    init(source: FeedSource, siteURL: String? = nil) {
        self.init(
            title: source.title,
            feedURL: source.url,
            siteURL: siteURL,
            category: source.category,
            region: source.region,
            mediaKind: source.mediaKind,
            language: source.language,
            sourceDescription: source.sourceDescription,
            tags: source.tags,
            nature: source.nature,
            activity: source.activity,
            qualityScore: source.qualityScore,
            defaultEnabled: source.defaultEnabled,
            contactEmail: source.contactEmail,
            contactName: source.contactName,
            contactSource: source.contactSource,
            contactType: source.contactType
        )
    }

    var feedSource: FeedSource {
        FeedSource(
            title: title,
            url: feedURL,
            category: category,
            region: region,
            mediaKind: mediaKind,
            language: language,
            sourceDescription: sourceDescription,
            tags: tags,
            nature: nature,
            activity: activity,
            qualityScore: qualityScore,
            defaultEnabled: defaultEnabled,
            contactEmail: contactEmail,
            contactName: contactName,
            contactSource: contactSource,
            contactType: contactType
        )
    }
}
