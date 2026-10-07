import SwiftUI

/// The consent prompt: a bottom-center card that names a disruptive action and waits for the
/// human to hold **Y**, **A** or **N**. The fill under each choice grows with the hold, so a
/// deliberate one-second press reads as intent and a stray tap visibly does nothing.
struct ConsentView: View {
    let model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(EffectsRenderer.amber)
                Text("Approve this action?")
                    .font(.system(size: 13, weight: .semibold))
            }

            if let consent = model.consent {
                Text(consent.prompt)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 332, alignment: .leading)
                if !consent.detail.isEmpty {
                    Text(consent.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                ConsentChoice(title: "Approve", key: "Y", tint: .green, fraction: fraction(.approve))
                ConsentChoice(
                    title: "All for \(StandingApproval.minutes) min", key: "A", tint: .blue,
                    fraction: fraction(.approveForAWhile),
                )
                ConsentChoice(title: "Decline", key: "N", tint: .gray, fraction: fraction(.decline))
            }
            .padding(.top, 1)

            Text("Hold the key for one second — a tap won't answer. ⌃⌥⇧⎋ ends an approval early.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(width: 360)
        // The panel's own surface, amber-edged: this card is the panel asking a question.
        .modifier(PanelChrome(accent: EffectsRenderer.amber))
        .accessibilityHidden(true)
    }

    private func fraction(_ answer: ConsentAnswer) -> Double {
        guard let hold = model.consentHold, hold.answer == answer else { return 0 }
        return hold.fraction
    }
}

private struct ConsentChoice: View {
    let title: String
    let key: String
    let tint: Color
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.16))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.5))
                    .frame(width: geometry.size.width * fraction)
            }
            HStack(spacing: 7) {
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.14)))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
        }
        .frame(height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
