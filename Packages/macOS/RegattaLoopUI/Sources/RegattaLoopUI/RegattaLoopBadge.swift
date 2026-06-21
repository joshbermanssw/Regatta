public import SwiftUI
import RegattaCore

/// A compact, tappable loop badge for a worker row in the Fleet.
///
/// Shows a loop glyph plus the worker's loop phase and iteration progress, and
/// opens the loop view when tapped. It is a leaf view that receives only value
/// snapshots and an action closure — no view model or store reference — so it is
/// safe inside a Fleet list's `LazyVStack` snapshot boundary.
///
/// ## Usage
/// ```swift
/// RegattaLoopBadge(
///     phase: worker.loopPhase,
///     completedIterations: worker.loopIterations,
///     onOpen: { openLoopView(worker.id) }
/// )
/// ```
public struct RegattaLoopBadge: View {
    private let phase: RegattaLoopRunPhase
    private let completedIterations: Int
    private let onOpen: () -> Void

    /// Creates a loop badge.
    ///
    /// - Parameters:
    ///   - phase: The worker's current loop phase.
    ///   - completedIterations: Iterations completed so far (shown when > 0).
    ///   - onOpen: Invoked when the badge is tapped to open the loop view.
    public init(
        phase: RegattaLoopRunPhase,
        completedIterations: Int,
        onOpen: @escaping () -> Void
    ) {
        self.phase = phase
        self.completedIterations = completedIterations
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 3) {
                Image(systemName: phase.isActive ? "arrow.triangle.2.circlepath" : "repeat")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(tint.opacity(0.15))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "regatta.loop.badge.help", defaultValue: "Open the loop view"))
        .accessibilityLabel(
            String(localized: "regatta.loop.badge.a11y", defaultValue: "Loop")
        )
        .accessibilityIdentifier("RegattaLoopBadge")
    }

    private var label: String {
        if completedIterations > 0 {
            return String(
                format: String(
                    localized: "regatta.loop.badge.iterations",
                    defaultValue: "Loop · %lld"
                ),
                completedIterations
            )
        }
        return String(localized: "regatta.loop.badge.title", defaultValue: "Loop")
    }

    private var tint: Color {
        switch phase {
        case .running:
            return .blue
        case .paused, .editing:
            return .orange
        case .finished(let status):
            switch status {
            case .failed:
                return .red
            case .stopped(let reason):
                return reason.isSafetyCap ? .orange : .green
            default:
                return .secondary
            }
        case .idle:
            return .secondary
        }
    }
}
