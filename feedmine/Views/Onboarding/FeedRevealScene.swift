import SwiftUI

/// Final onboarding screen — shows what the feed will look like.
/// Replaces the technical review page with a human-readable preview.
struct FeedRevealScene: View {
    let profile: CuratedProfileDefinition
    @Binding var feedName: String
    let accent: Color
    let previewItems: [FeedItem]
    let isSaving: Bool
    let onSave: () -> Void
    let onOpenHood: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Headline
                VStack(spacing: 8) {
                    Text("Here's your first mix.")
                        .font(.system(size: 29, weight: .bold))
                    Text("Built and stored on this device. Editable anytime.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }
                .padding(.top, 16)

                // Preference summary chips
                PreferenceSummaryChips(
                    profile: profile,
                    accent: accent,
                    onAdjust: nil
                )
                .padding(.horizontal, 22)

                // Name — optional, pre-filled
                VStack(alignment: .leading, spacing: 6) {
                    Text("NAME")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    TextField("Feed name", text: $feedName)
                        .font(.headline)
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal, 22)

                // Preview cards
                if !previewItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR FIRST STORIES")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 22)

                        ForEach(previewItems.prefix(3)) { item in
                            FeedItemCardView(item: item)
                                .padding(.horizontal, 16)
                        }
                    }
                }

                // CTAs
                VStack(spacing: 14) {
                    Button(action: onSave) {
                        Group {
                            if isSaving {
                                ProgressView().tint(.white)
                            } else {
                                Text("Open my feed")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .disabled(isSaving)
                    .padding(.horizontal, 22)
                    .accessibilityIdentifier("reveal-save")

                    Button(action: onOpenHood) {
                        Text("See everything Feedmine learned")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reveal-open-hood")
                }
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
    }
}
