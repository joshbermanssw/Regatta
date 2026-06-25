import SwiftUI
import RegattaCore

/// A pure, value-typed projection of a ``WorkerStatus`` into the legible pieces
/// the Fleet UI renders: a plain status label, an optional reason detail, the
/// status-dot colour category, and whether the status needs the human's
/// attention.
///
/// ## Why a shared value type
/// The Fleet rail row (``WorkerRow``) and the Open-Fleet-grid cell (``WorkerCell``)
/// both render a worker's status. Before this type each surface carried its own
/// duplicated `switch worker.status` for the label *and* the colour, so a change to
/// one (e.g. clarifying "Done" → "Done — succeeded") risked drifting from the
/// other. This is the single shared presentation path both surfaces consume
/// (CLAUDE.md shared-behavior policy), and it is unit-testable without booting
/// AppKit (see `WorkerStatusPresentationTests`).
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// Built from a plain ``WorkerStatus`` value; holds no store/actor reference. Safe
/// to construct inside a row body from the row's value snapshot.
struct WorkerStatusPresentation: Equatable {

    /// The coarse semantic category a worker status falls into — drives the dot
    /// colour and the "needs attention" affordance, decoupled from the exact case.
    enum Category: Equatable {
        /// Accepted but not yet started (held behind the concurrency cap).
        case queued
        /// Actively running.
        case running
        /// Finished successfully.
        case succeeded
        /// Finished with an error — needs attention.
        case failed
        /// Parked awaiting human resolution (work intact) — needs attention.
        case blocked
        /// Cancelled by the human.
        case cancelled
        /// Work was cut off by a restart and can be relaunched — needs attention.
        case interrupted
    }

    /// The short, plain status label, e.g. "Running" or "Done — succeeded".
    let label: String

    /// A one-line reason/detail for statuses that carry one (failed / blocked),
    /// shown beneath the label so the human sees *why* at a glance. `nil` otherwise.
    let detail: String?

    /// The coarse semantic category for colour + needs-attention derivation.
    let category: Category

    /// Whether this status needs the human's attention (failed / blocked /
    /// interrupted). The UI tints these and can surface a marker.
    var needsAttention: Bool {
        switch category {
        case .failed, .blocked, .interrupted:
            return true
        case .queued, .running, .succeeded, .cancelled:
            return false
        }
    }

    /// Projects a worker status into its legible presentation.
    init(_ status: WorkerStatus) {
        switch status {
        case .queued:
            label = String(localized: "regatta.fleet.status.queued", defaultValue: "Queued")
            detail = nil
            category = .queued
        case .running:
            label = String(localized: "regatta.fleet.status.running", defaultValue: "Running")
            detail = nil
            category = .running
        case .done:
            // Disambiguate the bare "Done" so the human knows it *succeeded* and
            // did not silently give up (state-legibility goal).
            label = String(localized: "regatta.fleet.status.done.succeeded", defaultValue: "Done — succeeded")
            detail = nil
            category = .succeeded
        case .failed(let reason):
            label = String(localized: "regatta.fleet.status.failed.label", defaultValue: "Failed")
            detail = Self.cleaned(reason)
            category = .failed
        case .blocked(let reason):
            label = String(localized: "regatta.fleet.status.blocked.label", defaultValue: "Blocked — needs attention")
            detail = Self.cleaned(reason)
            category = .blocked
        case .cancelled:
            label = String(localized: "regatta.fleet.status.cancelled", defaultValue: "Cancelled")
            detail = nil
            category = .cancelled
        case .interrupted:
            label = String(localized: "regatta.fleet.status.interrupted.label", defaultValue: "Interrupted — can relaunch")
            detail = nil
            category = .interrupted
        }
    }

    /// A single-line accessibility/summary string combining label and detail.
    var accessibilitySummary: String {
        guard let detail, !detail.isEmpty else { return label }
        return "\(label): \(detail)"
    }

    /// The status-dot colour for this category.
    var dotColor: Color {
        switch category {
        case .queued:      return .secondary
        case .running:     return .blue
        case .succeeded:   return .green
        case .failed:      return .red
        case .blocked:     return .yellow
        case .cancelled:   return .orange
        case .interrupted: return .yellow
        }
    }

    /// Trims and collapses a raw reason string so it renders cleanly on one line.
    private static func cleaned(_ reason: String) -> String? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
