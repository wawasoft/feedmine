import SwiftUI

struct ToastView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline)
            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.8), in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
    }
}
