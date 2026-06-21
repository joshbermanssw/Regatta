public import RegattaGitHub
import Foundation

/// A long-lived watcher that polls one pull request's CI checks and review
/// threads and publishes ``ShepherdState`` snapshots.
///
/// The watcher is an `actor`: all mutable state is actor-isolated. Observers
/// subscribe via ``states()``, which returns an `AsyncStream` that immediately
/// replays the current state and then yields a fresh snapshot after every poll.
///
/// ## Polling
/// Call ``start()`` to begin the recurring poll loop. Each cycle:
/// 1. fetch checks + review threads through the injected ``PullRequestPolling``,
/// 2. publish a new ``ShepherdState`` (phase `.watching` on success, `.failed`
///    on error while preserving the last good data),
/// 3. wait one ``pollInterval`` on the injected `Clock`, then repeat.
///
/// Driving the delay from an injected `ContinuousClock` keeps tests fast: a test
/// can call ``pollOnce()`` directly and assert the published snapshot without
/// ever advancing real time.
///
/// ## Concurrency
/// The poll interval uses `Clock.sleep`, which is the sanctioned bounded,
/// cancellable delay carve-out (the interval *is* the intended behaviour, not a
/// busy-wait for a condition). ``stop()`` cancels the loop task, which cancels
/// the in-flight sleep.
public actor ShepherdWatcher {
    private let pullRequest: PullRequestRef
    private let poller: any PullRequestPolling
    private let pollInterval: Duration
    private let maxBackoff: Duration

    private var current: ShepherdState
    private var loopTask: Task<Void, Never>?

    /// The current backoff streak. Each consecutive pause-worthy failure
    /// (auth/rate-limit) doubles the delay; a successful poll resets it. Drives
    /// the exponential backoff the loop sleeps for while paused (issue #35).
    private var consecutivePauses = 0

    /// Live subscribers' continuations, keyed by a token so they can be removed
    /// when their stream terminates.
    private var continuations: [UUID: AsyncStream<ShepherdState>.Continuation] = [:]

    /// Creates a watcher for one pull request.
    ///
    /// - Parameters:
    ///   - pullRequest: The PR to watch.
    ///   - poller: The polling seam; inject ``GitHubPoller`` in production or a
    ///     fake in tests.
    ///   - pollInterval: How long to wait between poll cycles. Defaults to 30s.
    ///   - maxBackoff: The ceiling on the exponential backoff applied after
    ///     consecutive auth/rate-limit failures. Defaults to 15 minutes.
    public init(
        pullRequest: PullRequestRef,
        poller: any PullRequestPolling,
        pollInterval: Duration = .seconds(30),
        maxBackoff: Duration = .seconds(900)
    ) {
        self.pullRequest = pullRequest
        self.poller = poller
        self.pollInterval = pollInterval
        self.maxBackoff = maxBackoff
        self.current = ShepherdState(pullRequest: pullRequest, phase: .starting)
    }

    /// The most recently published state. Useful for tests and one-shot reads.
    public var state: ShepherdState { current }

    /// Returns an `AsyncStream` that replays the current state and then yields a
    /// new snapshot after each poll.
    ///
    /// The stream finishes when the watcher is stopped. Multiple concurrent
    /// subscribers are supported; each receives every subsequent snapshot.
    public func states() -> AsyncStream<ShepherdState> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    /// Starts the recurring poll loop. Idempotent — a second call is a no-op
    /// while a loop is already running.
    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                // When the shepherd paused after an auth/rate-limit failure it
                // sleeps for the (exponentially growing) backoff instead of the
                // normal interval before retrying (issue #35).
                let delay = await self.nextDelay()
                do {
                    // Bounded, cancellable interval between polls (delay carve-out).
                    try await Task.sleep(for: delay)
                } catch {
                    break // cancelled
                }
            }
        }
    }

    /// Performs a single poll cycle and publishes the resulting snapshot.
    ///
    /// Exposed so tests can drive exactly one cycle deterministically without
    /// waiting on the interval. On failure the previous good ``checks`` /
    /// ``reviewThreads`` are preserved and the phase becomes `.failed`.
    public func pollOnce() async {
        do {
            let checks = try await poller.fetchChecks(
                owner: pullRequest.owner, repo: pullRequest.repo, prNumber: pullRequest.number
            )
            let threads = try await poller.fetchReviewThreads(
                owner: pullRequest.owner, repo: pullRequest.repo, prNumber: pullRequest.number
            )
            // A clean poll clears any backoff streak.
            consecutivePauses = 0
            publish(ShepherdState(
                pullRequest: pullRequest,
                phase: .watching,
                checks: PRCheckSummary(checks: checks),
                reviewThreads: threads
            ))
        } catch {
            // A `gh` auth or rate-limit failure pauses the shepherd and backs off
            // exponentially before retrying, preserving the last good data; any
            // other failure is a transient `.failed` retried on the normal
            // interval (issue #35).
            if let gh = error as? GitHubCommandError, gh.shouldPauseShepherd {
                consecutivePauses += 1
                let retryAfter = backoffDelay(for: consecutivePauses)
                publish(ShepherdState(
                    pullRequest: pullRequest,
                    phase: .paused(reason: Self.describe(error), retryAfter: retryAfter),
                    checks: current.checks,
                    reviewThreads: current.reviewThreads,
                    autonomyMode: current.autonomyMode,
                    needsAttention: current.needsAttention
                ))
                return
            }
            // Preserve last good data; only the phase reflects the transient failure.
            consecutivePauses = 0
            publish(ShepherdState(
                pullRequest: pullRequest,
                phase: .failed(Self.describe(error)),
                checks: current.checks,
                reviewThreads: current.reviewThreads
            ))
        }
    }

    /// The delay to sleep before the next poll: the backoff while paused, else the
    /// normal interval.
    private func nextDelay() -> Duration {
        if case .paused(_, let retryAfter) = current.phase {
            return retryAfter
        }
        return pollInterval
    }

    /// Exponential backoff: `pollInterval × 2^(streak-1)`, clamped to ``maxBackoff``.
    private func backoffDelay(for streak: Int) -> Duration {
        guard streak > 0 else { return pollInterval }
        let multiplier = 1 << min(streak - 1, 16)
        let scaled = pollInterval * multiplier
        return scaled < maxBackoff ? scaled : maxBackoff
    }

    /// Stops the poll loop and finishes all subscriber streams. Idempotent.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    // MARK: - Private

    private func publish(_ next: ShepherdState) {
        current = next
        for continuation in continuations.values {
            continuation.yield(next)
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuations[token] = nil
    }

    private static func describe(_ error: any Error) -> String {
        if let gh = error as? GitHubCommandError {
            switch gh {
            case .nonZeroExit(_, let stderr):
                return stderr?.isEmpty == false ? stderr! : "gh command failed"
            case .timedOut:
                return "gh request timed out"
            case .launchFailed(let message):
                return "could not launch gh: \(message)"
            case .outputDecodingFailed:
                return "could not decode gh output"
            case .jsonDecodingFailed(let message):
                return "could not parse gh output: \(message)"
            }
        }
        return error.localizedDescription
    }
}
