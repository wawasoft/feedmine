import SwiftUI

/// Three-state qualitative progress replacing numeric "CHOICE N of 14".
/// States: "Finding your range" → "A pattern is forming" → "Your first mix is ready"
struct ConfidenceProgressView: View {
    let answerCount: Int
    let isReady: Bool
    let accent: Color

    private enum Phase: Int {
        case finding = 0
        case forming = 1
        case ready = 2

        var label: String {
            switch self {
            case .finding: return "Finding your range"
            case .forming: return "A pattern is forming"
            case .ready: return "Your first mix is ready"
            }
        }
    }

    private var phase: Phase {
        if isReady { return .ready }
        if answerCount >= 3 { return .forming }
        return .finding
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 24) {
                ForEach(0..<3) { i in
                    let active = i <= phase.rawValue
                    let isCurrent = i == phase.rawValue
                    Circle()
                        .fill(active ? accent : accent.opacity(0.15))
                        .frame(
                            width: isCurrent ? 14 : (active ? 10 : 6),
                            height: isCurrent ? 14 : (active ? 10 : 6)
                        )
                        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: phase)
                }
            }

            Text(phase.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .animation(.easeInOut(duration: 0.3), value: phase)
        }
    }
}
