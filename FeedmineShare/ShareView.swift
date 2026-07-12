import SwiftUI

struct ShareConfirmationView: View {
    let itemCount: Int
    let feedCount: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Sent to Feedmine")
                .font(.title2)
                .fontWeight(.bold)

            if feedCount > 0 {
                Text("\(feedCount) feed\(feedCount == 1 ? "" : "s") found across \(itemCount) source\(itemCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button("Open Feedmine") {
                    // Extensions cannot directly open URLs; dismiss and let the
                    // user open Feedmine manually from the home screen.
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
