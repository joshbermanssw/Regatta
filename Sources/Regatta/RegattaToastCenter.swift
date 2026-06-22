import Foundation
import Observation

/// The app-lifetime center that owns the bottom-right toast queue for every
/// Regatta action's success/error feedback.
///
/// ## Why a singleton seam
/// Like ``RegattaFleetManager`` / ``RegattaSummonManager`` / ``RegattaBrainManager``,
/// every Regatta surface (the Fleet rail, the Summon overlay, the Brain composer,
/// the handoff action) needs to emit into the *same* toast stack, and there is no
/// other injection path between those separately-hosted views and a single
/// app-wide overlay. The seam holds only the queue and the auto-dismiss timers.
///
/// ## Concurrency
/// `@MainActor @Observable` — ``toasts`` is read directly by the overlay's SwiftUI
/// `body`. Auto-dismiss uses a bounded, cancellable `Task` sleeping on an injected
/// ``Clock`` (the carve-out for a genuine timed delay), so tests advance virtual
/// time with no real waiting and never spin a runloop.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// The overlay reads ``toasts`` (a flat array of value-typed ``RegattaToast``)
/// above its `ForEach` and passes value copies plus a dismiss closure into rows.
/// No reference to this center crosses the list boundary.
@MainActor
@Observable
final class RegattaToastCenter {

    /// The shared app-lifetime instance used by every Regatta action.
    static let shared = RegattaToastCenter()

    /// The maximum number of toasts kept on screen at once. When a new toast
    /// would exceed this, the oldest is dropped so the stack never overflows.
    static let maxStack = 4

    /// The live toast stack, oldest first. Read directly by the overlay.
    private(set) var toasts: [RegattaToast] = []

    /// The injected clock backing auto-dismiss delays. `@ObservationIgnored`
    /// because it is an internal dependency, not UI-observable.
    @ObservationIgnored
    private let clock: any Clock<Duration>

    /// Whether auto-dismiss is enabled. Disabled in tests that assert the queue
    /// deterministically without virtual-time juggling.
    @ObservationIgnored
    private let autoDismissEnabled: Bool

    /// Provides "now" for toast timestamps, injectable for deterministic tests.
    @ObservationIgnored
    private let now: @MainActor () -> Date

    /// The per-toast auto-dismiss tasks, keyed by toast id, cancelled on manual
    /// dismiss or when the toast is dropped from the stack.
    @ObservationIgnored
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    /// Creates a toast center.
    ///
    /// - Parameters:
    ///   - clock: The clock backing auto-dismiss delays (defaults to a
    ///     `ContinuousClock`). Tests inject a controllable clock.
    ///   - autoDismissEnabled: Whether toasts auto-dismiss after their kind's
    ///     timeout (defaults to `true`). Tests pass `false` to assert the queue
    ///     synchronously.
    ///   - now: Supplies the creation timestamp (defaults to `Date.init`).
    init(
        clock: any Clock<Duration> = ContinuousClock(),
        autoDismissEnabled: Bool = true,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.clock = clock
        self.autoDismissEnabled = autoDismissEnabled
        self.now = now
    }

    // MARK: - Emit API

    /// Enqueues a success toast (green, checkmark).
    ///
    /// - Parameters:
    ///   - title: The bold headline line.
    ///   - message: An optional secondary detail line.
    func success(_ title: String, _ message: String? = nil) {
        enqueue(RegattaToast(kind: .success, title: title, message: message, createdAt: now()))
    }

    /// Enqueues an error toast (red, exclamation); lingers longer than the rest.
    ///
    /// - Parameters:
    ///   - title: The bold headline line.
    ///   - message: An optional secondary detail line.
    func error(_ title: String, _ message: String? = nil) {
        enqueue(RegattaToast(kind: .error, title: title, message: message, createdAt: now()))
    }

    /// Enqueues an informational toast (blue, info).
    ///
    /// - Parameters:
    ///   - title: The bold headline line.
    ///   - message: An optional secondary detail line.
    func info(_ title: String, _ message: String? = nil) {
        enqueue(RegattaToast(kind: .info, title: title, message: message, createdAt: now()))
    }

    // MARK: - Dismiss API

    /// Dismisses the toast with the given id, cancelling its auto-dismiss timer.
    func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        toasts.removeAll { $0.id == id }
    }

    /// Dismisses every toast, cancelling all pending auto-dismiss timers.
    func dismissAll() {
        for task in dismissTasks.values { task.cancel() }
        dismissTasks.removeAll()
        toasts.removeAll()
    }

    // MARK: - Queue mechanics

    /// Inserts `toast`, coalescing into an existing identical toast when present,
    /// trimming the oldest when over ``maxStack``, and arming auto-dismiss.
    private func enqueue(_ toast: RegattaToast) {
        // Coalesce a repeated identical result into the existing toast: bump its
        // count and refresh its auto-dismiss timer rather than stacking a clone.
        if let index = toasts.firstIndex(where: { $0.coalesces(with: toast) }) {
            toasts[index].count += 1
            let existingID = toasts[index].id
            armAutoDismiss(for: existingID, kind: toasts[index].kind)
            return
        }

        toasts.append(toast)

        // Overflow: drop the oldest toasts (and their timers) so the visible
        // stack never grows past the cap.
        while toasts.count > Self.maxStack {
            let dropped = toasts.removeFirst()
            dismissTasks[dropped.id]?.cancel()
            dismissTasks[dropped.id] = nil
        }

        armAutoDismiss(for: toast.id, kind: toast.kind)
    }

    /// Arms (or re-arms) the auto-dismiss timer for one toast. No-op when
    /// auto-dismiss is disabled (tests). The sleeping `Task` is bounded by the
    /// kind's timeout, cancellable, and driven by the injected clock.
    private func armAutoDismiss(for id: UUID, kind: RegattaToastKind) {
        guard autoDismissEnabled else { return }
        dismissTasks[id]?.cancel()
        let clock = self.clock
        // Bounded, cancellable delay on an injected clock — the auto-dismiss
        // carve-out (CLAUDE.md). Cancelled on manual dismiss / overflow drop.
        dismissTasks[id] = Task { [weak self] in
            try? await clock.sleep(for: kind.autoDismiss)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }
}
