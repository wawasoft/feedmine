import SwiftUI

/// Detects device shake gesture and triggers a callback.
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        ShakeViewController(onShake: onShake)
    }

    func updateUIViewController(_ uiViewController: ShakeViewController, context: Context) {
        uiViewController.onShake = onShake
    }

    final class ShakeViewController: UIViewController {
        var onShake: () -> Void

        init(onShake: @escaping () -> Void) {
            self.onShake = onShake
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("ShakeViewController does not support storyboard deserialization") }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            if motion == .motionShake { onShake() }
        }
    }
}
