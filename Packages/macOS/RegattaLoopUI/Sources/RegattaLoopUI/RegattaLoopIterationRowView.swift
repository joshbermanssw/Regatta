import SwiftUI
import RegattaCore

/// A single iteration-history row. Receives a ``RegattaLoopIterationRow`` value
/// snapshot only — no view model or store reference (snapshot-boundary rule).
struct RegattaLoopIterationRowView: View {
    let row: RegattaLoopIterationRow

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            outcomeBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(
                        String(
                            format: String(
                                localized: "regatta.loop.iteration.index",
                                defaultValue: "Iteration %lld"
                            ),
                            row.index + 1
                        )
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)

                    Spacer(minLength: 4)

                    Text(metaLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(row.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private var outcomeBadge: some View {
        Text(badgeLabel)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(badgeColor.opacity(0.15))
            )
            .fixedSize()
            .accessibilityLabel(badgeAccessibilityLabel)
    }

    private var metaLine: String {
        let seconds = String(format: "%.1f", row.duration)
        if row.tokensUsed > 0 {
            return String(
                format: String(
                    localized: "regatta.loop.iteration.meta.full",
                    defaultValue: "%@s · %lld tok"
                ),
                seconds,
                row.tokensUsed
            )
        }
        return String(
            format: String(
                localized: "regatta.loop.iteration.meta.duration",
                defaultValue: "%@s"
            ),
            seconds
        )
    }

    private var badgeLabel: String {
        switch row.kind {
        case .succeeded:
            return String(localized: "regatta.loop.iteration.badge.succeeded", defaultValue: "OK")
        case .progressed:
            return String(localized: "regatta.loop.iteration.badge.progressed", defaultValue: "···")
        case .failed:
            return String(localized: "regatta.loop.iteration.badge.failed", defaultValue: "X")
        case .cancelled:
            return String(localized: "regatta.loop.iteration.badge.cancelled", defaultValue: "⊘")
        }
    }

    private var badgeAccessibilityLabel: String {
        switch row.kind {
        case .succeeded:
            return String(localized: "regatta.loop.iteration.badge.succeeded.a11y", defaultValue: "Succeeded")
        case .progressed:
            return String(localized: "regatta.loop.iteration.badge.progressed.a11y", defaultValue: "Progressed")
        case .failed:
            return String(localized: "regatta.loop.iteration.badge.failed.a11y", defaultValue: "Failed")
        case .cancelled:
            return String(localized: "regatta.loop.iteration.badge.cancelled.a11y", defaultValue: "Cancelled")
        }
    }

    private var badgeColor: Color {
        switch row.kind {
        case .succeeded: return .green
        case .progressed: return .blue
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
