import SwiftUI

/// A single toast card in the bottom-right stack.
///
/// Receives an immutable ``RegattaToast`` value snapshot plus a dismiss closure
/// (snapshot-boundary rule): it never reads ``RegattaToastCenter``. The kind drives
/// a colored leading rail and a tinted icon badge so success/error/info are
/// distinguishable at a glance.
struct RegattaToastRowView: View {
    let toast: RegattaToast
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.kind.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(toast.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if toast.count > 1 {
                        countChip
                    }
                }
                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "regatta.toast.dismiss.help", defaultValue: "Dismiss"))
                .accessibilityLabel(String(localized: "regatta.toast.dismiss.a11y", defaultValue: "Dismiss notification"))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(width: 320, alignment: .leading)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentColor.opacity(0.06))
                // Signature: a kind-tinted leading rail anchoring the card.
                accentColor
                    .frame(width: 3)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10,
                            bottomLeadingRadius: 10,
                            style: .continuous
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(accentColor.opacity(0.22), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var countChip: some View {
        Text("×\(toast.count)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule(style: .continuous).fill(accentColor.opacity(0.16)))
    }

    private var accentColor: Color {
        switch toast.kind {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        }
    }

    /// A combined spoken label so VoiceOver announces the kind, title, and detail
    /// as one notification.
    private var accessibilityText: String {
        let kindWord: String
        switch toast.kind {
        case .success: kindWord = String(localized: "regatta.toast.kind.success", defaultValue: "Success")
        case .error: kindWord = String(localized: "regatta.toast.kind.error", defaultValue: "Error")
        case .info: kindWord = String(localized: "regatta.toast.kind.info", defaultValue: "Notice")
        }
        let body = [toast.title, toast.message].compactMap { $0 }.joined(separator: ". ")
        return "\(kindWord). \(body)"
    }
}
