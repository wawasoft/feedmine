import SwiftUI

/// Wraps a single feed item with all its modifiers,
/// extracted from FeedScreen to reduce type-checking complexity.
struct FeedItemView: View {
    @Environment(FeedLoader.self) private var loader
    let item: FeedItem
    /// Pre-resolved card presentation from the prepared pipeline.
    /// When non-nil and media is .image, the card renders the UIImage
    /// directly via PreparedCardImage — zero async work. When nil,
    /// falls back to looking up the card from loader.cards.
    var presentation: FeedCardPresentation? = nil
    var onOpen: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onViewSource: (() -> Void)? = nil
    var onAddSourceToCollection: (() -> Void)? = nil

    var body: some View {
        let isDirectAudio = item.isDirectAudioLink
        let pres = presentation ?? loader.cards.first { $0.id == item.id }
        Group {
            if loader.layout == .card {
                FeedItemCardView(
                    item: item,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked,
                    presentation: pres,
                    onBookmark: { loader.toggleBookmark(item.id) },
                    onViewSource: onViewSource,
                    onAddSourceToCollection: onAddSourceToCollection,
                    onCopy: onCopy,
                    onImageTap: (item.isPodcast && !isDirectAudio) ? { playPodcastAudio() } : nil,
                    isInBookmarkBox: loader.selectedBookmarkListID != nil
                )
                .padding(.horizontal, 12)
            } else {
                // Row layout owns its context menu here. The card layout renders
                // FeedItemCardView's own menu instead — attaching both menus to
                // the same area makes the inner (card) one win and the outer one
                // unreachable, so the menu must not apply to the card branch.
                FeedItemRowView(
                    item: item,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked,
                    presentation: pres,
                    onImageTap: (item.isPodcast && !isDirectAudio) ? { playPodcastAudio() } : nil
                )
                .contextMenu { contextMenuContent }
                Divider()
            }
        }
        .onTapGesture {
            // Diagnostic for the release review's ignored-tap class: this line is what separates "the synthesized tap
            // never reached the app's gesture" from "the app got the tap and the reader did not open". The observation
            // that costs the least to answer — the 20 s miss of 2026-09-17 could not be attributed without it, because
            // the device log for that window had already rotated away.
            Log.ui.info("card tap id=\(item.id) lang=\(item.language ?? "und") directAudio=\(isDirectAudio) podcast=\(item.isPodcast) read=\(item.isRead)")
            let impact = UIImpactFeedbackGenerator(style: .light)
            impact.impactOccurred()
            if isDirectAudio {
                // Direct audio link (e.g. .mp3) — whole card plays audio.
                playPodcastAudio()
            } else if item.isPodcast {
                // Podcast with article page — image tap plays audio,
                // text area tap opens the link.
                loader.markAsClicked(item.id)
                onOpen?()
            } else {
                loader.markAsClicked(item.id)
                onOpen?()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed-item-\(item.language ?? "und")-\(item.id)")
        .accessibilityLabel("\(item.title) from \(item.sourceTitle)")
    }

    /// Row-layout context menu, functionally equivalent to the card's own menu.
    /// Cards use FeedItemCardView.cardContextMenu instead; an outer menu on the
    /// shared area would be shadowed by the inner one (see the row-branch note).
    @ViewBuilder
    private var contextMenuContent: some View {
        BookmarkBoxContextMenu(itemID: item.id)

        if let onViewSource {
            Button(action: onViewSource) {
                Label("View Source", systemImage: "rectangle.stack")
            }
        }

        if let onAddSourceToCollection {
            Button(action: onAddSourceToCollection) {
                Label("Add Source to Collection", systemImage: "rectangle.stack.badge.plus")
            }
        }

        Button {
            UIPasteboard.general.url = URL(string: item.url)
            onCopy?()
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }
        Button {
            if let image = renderCardAsImage(item: item) {
                let av = UIActivityViewController(activityItems: [image], applicationActivities: nil)
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = windowScene.windows.first?.rootViewController {
                    root.present(av, animated: true)
                }
            }
        } label: {
            Label("Share as Image", systemImage: "photo.artframe")
        }

        ShareLink(item: URL(string: item.url) ?? URL(string: "https://feedmine.app")!) {
            Label("Share Link", systemImage: "link")
        }
    }

    private func playPodcastAudio() {
        if AudioPlayerManager.shared.play(item: item) {
            loader.markAsClicked(item.id)
        } else {
            onPlaybackFailed?()
        }
    }
}
