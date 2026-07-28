import SwiftUI

/// A full-width story card for the vertical comparison layout.
/// Shows only source, image, title, and format badge during choice —
/// no editorial labels, no A/B markers, no "I'd open this" prompt.
struct StoryDuelCard: View {
    let candidate: CuratedCandidate
    let accent: Color
    let action: () -> Void

    @State private var imageFailed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                // Source label + format badge
                HStack {
                    Text(candidate.item.sourceTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Spacer()
                    if candidate.item.isPodcast {
                        Label("Podcast", systemImage: "headphones")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if candidate.item.youTubeVideoID != nil {
                        Label("Video", systemImage: "play.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Artwork — full width, 16:9
                artwork
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()

                // Title
                Text(candidate.item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.06), lineWidth: 0.6)
            )
        }
        .buttonStyle(CuratedPressStyle())
        .accessibilityIdentifier("duel-card")
    }

    @ViewBuilder
    private var artwork: some View {
        GeometryReader { geometry in
            ZStack {
                // Placeholder gradient
                LinearGradient(
                    colors: [
                        ComponentToken.categoryColor(for: candidate.item.category).opacity(0.48),
                        accent.opacity(0.16),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: candidate.topic.icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.82))

                if candidate.item.hasPotentialImage, !imageFailed {
                    CachedAsyncImage(
                        url: candidate.item.bestImageURL.flatMap(URL.init(string:)),
                        articleURL: candidate.item.canResolveArticleImage
                            ? URL(string: candidate.item.url) : nil,
                        onResult: { success in imageFailed = !success }
                    )
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
}
