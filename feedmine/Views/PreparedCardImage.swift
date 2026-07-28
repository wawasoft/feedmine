import SwiftUI

/// A zero-async image view for feed cards. Renders a pre-resolved UIImage or
/// nothing — never starts a download, never triggers a network request, never
/// animates opacity. The card's own placeholder (heroBase) sits underneath in
/// the ZStack and shows through when this view produces EmptyView.
struct PreparedCardImage: View {
    let media: ResolvedCardMedia

    var body: some View {
        switch media {
        case .image(let uiImage):
            Image(uiImage: uiImage)
                .resizable()
        case .placeholder, .none:
            EmptyView()
        }
    }
}
