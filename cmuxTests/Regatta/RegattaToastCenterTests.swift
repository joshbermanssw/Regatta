import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``RegattaToastCenter``: enqueue + kinds, coalescing, max-stack
/// overflow, manual dismiss, and clock-driven auto-dismiss.
///
/// Queue-mechanics tests construct the center with `autoDismissEnabled: false` so
/// the queue is asserted deterministically with no timers. The auto-dismiss test
/// uses an injected ``GateClock`` whose `sleep` only returns when the test opens
/// the gate, so virtual time is fully controlled — no real waiting, no runloop
/// spinning.
@Suite("RegattaToastCenter")
@MainActor
struct RegattaToastCenterTests {

    // MARK: - Kinds + enqueue

    @Test("success/error/info enqueue toasts of the matching kind")
    func enqueueKinds() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        center.success("a")
        center.error("b")
        center.info("c")
        #expect(center.toasts.map(\.kind) == [.success, .error, .info])
        #expect(center.toasts.map(\.title) == ["a", "b", "c"])
    }

    @Test("message is carried through")
    func carriesMessage() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        center.error("title", "detail")
        #expect(center.toasts.first?.message == "detail")
    }

    @Test("toasts are ordered oldest-first by insertion")
    func insertionOrder() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        for index in 0..<3 { center.info("t\(index)") }
        #expect(center.toasts.map(\.title) == ["t0", "t1", "t2"])
    }

    // MARK: - Coalescing

    @Test("identical toasts coalesce into one with a bumped count")
    func coalesceIdentical() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        center.success("Handed PR #1 to Regatta", "watching")
        center.success("Handed PR #1 to Regatta", "watching")
        center.success("Handed PR #1 to Regatta", "watching")
        #expect(center.toasts.count == 1)
        #expect(center.toasts.first?.count == 3)
    }

    @Test("toasts differing in kind, title, or message do not coalesce")
    func noCoalesceWhenDifferent() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        center.success("same")
        center.error("same")          // different kind
        center.success("same", "msg") // different message
        center.success("other")       // different title
        #expect(center.toasts.count == 4)
        #expect(center.toasts.allSatisfy { $0.count == 1 })
    }

    // MARK: - Max stack overflow

    @Test("stack never exceeds maxStack; oldest are dropped")
    func overflowDropsOldest() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        for index in 0..<(RegattaToastCenter.maxStack + 3) {
            center.info("t\(index)")
        }
        #expect(center.toasts.count == RegattaToastCenter.maxStack)
        // The oldest (t0…t2) were dropped; the most recent survive.
        #expect(center.toasts.first?.title == "t3")
        #expect(center.toasts.last?.title == "t\(RegattaToastCenter.maxStack + 2)")
    }

    // MARK: - Manual dismiss

    @Test("dismiss(id:) removes a specific toast")
    func dismissOne() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        center.success("keep")
        center.error("drop")
        let dropID = center.toasts[1].id
        center.dismiss(dropID)
        #expect(center.toasts.map(\.title) == ["keep"])
    }

    @Test("dismissAll empties the stack")
    func dismissEverything() {
        let center = RegattaToastCenter(autoDismissEnabled: false)
        center.success("a"); center.error("b"); center.info("c")
        center.dismissAll()
        #expect(center.toasts.isEmpty)
    }

    // MARK: - Auto-dismiss (clock-driven)

    @Test("auto-dismiss removes the toast once its delay elapses")
    func autoDismissFires() async {
        let clock = GateClock()
        let center = RegattaToastCenter(clock: clock, autoDismissEnabled: true)
        center.info("temp")
        #expect(center.toasts.count == 1)

        // Open the gate so the armed sleep returns, then let the dismissal task run.
        await clock.fire()
        await clock.waitForDismiss { center.toasts.isEmpty }
        #expect(center.toasts.isEmpty)
    }

    @Test("manual dismiss before the delay cancels auto-dismiss cleanly")
    func manualDismissCancelsTimer() async {
        let clock = GateClock()
        let center = RegattaToastCenter(clock: clock, autoDismissEnabled: true)
        center.info("temp")
        let id = center.toasts[0].id
        center.dismiss(id)
        #expect(center.toasts.isEmpty)
        // Firing the (now cancelled) gate must not crash or resurrect anything.
        await clock.fire()
        #expect(center.toasts.isEmpty)
    }
}

/// A controllable `Clock` whose `sleep(for:)` blocks until ``fire()`` is called,
/// so tests deterministically drive auto-dismiss with no real waiting.
private actor GateBox {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func fire() {
        fired = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}

private final class GateClock: Clock {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        let base: ContinuousClock.Instant
        func advanced(by duration: Duration) -> Instant { Instant(base: base.advanced(by: duration)) }
        func duration(to other: Instant) -> Duration { base.duration(to: other.base) }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.base < rhs.base }
    }

    private let box = GateBox()
    var now: Instant { Instant(base: ContinuousClock().now) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await box.wait()
    }

    /// Opens the gate, releasing every armed `sleep`.
    func fire() async { await box.fire() }

    /// Yields the main actor until `condition` holds, so the dismissal `Task`
    /// scheduled after the gate opens can run. Bounded so a hang fails fast.
    @MainActor
    func waitForDismiss(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }
}
