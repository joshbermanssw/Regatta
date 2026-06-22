import Foundation
import Observation
import RegattaBrain

/// The view-model that owns and drives a single ``BrainSession`` for the Regatta
/// Brain chat rail.
///
/// Lifecycle: call ``startIfNeeded()`` once when the rail becomes visible; call
/// ``shutdown()`` on app quit (via ``AppDelegate.applicationWillTerminate``).
///
/// ## Concurrency
/// `@MainActor @Observable` — all state is read on the main actor directly from
/// SwiftUI. The actor-isolated ``BrainSession`` is touched only through `await`
/// calls inside structured `Task`s owned by this class.
@MainActor
@Observable
final class RegattaBrainViewModel {

    // MARK: - Observable state

    /// The accumulated chat transcript. Read by ``BrainChatView``; rows receive
    /// value snapshots (``BrainMessage`` is a struct) — no store reference escapes
    /// the `LazyVStack` / `ForEach` boundary.
    private(set) var messages: [BrainMessage] = []

    /// Current session status, reflected in the chat UI chrome.
    private(set) var status: BrainStatus = .idle

    /// The currently-attached workspace tab context, shown as a removable chip
    /// above the composer. `nil` means no context is attached.
    var attachedContext: AttachedTabContext?

    // MARK: - Private non-observable state

    /// The actor that owns the subprocess. `@ObservationIgnored` because it is
    /// an internal resource handle, not UI-observable.
    @ObservationIgnored
    private var session: BrainSession?

    /// The structured `Task` consuming the ``BrainEvent`` stream.
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?

    /// The toast center for brain start/send failure feedback. Defaults to the
    /// shared app-lifetime instance; injectable for tests.
    @ObservationIgnored
    private let toasts: RegattaToastCenter

    /// Creates a brain view-model.
    ///
    /// - Parameter toasts: The toast center for failure feedback (defaults to the
    ///   shared instance).
    init(toasts: RegattaToastCenter = .shared) {
        self.toasts = toasts
    }

    // MARK: - Lifecycle

    /// Spawns the `claude` subprocess (if not already running) and begins
    /// consuming the event stream.
    ///
    /// Safe to call multiple times — only the first call takes effect. If `claude`
    /// cannot be found or fails to start, ``status`` is set to `.failed(…)` and
    /// no crash occurs.
    func startIfNeeded() {
        guard session == nil else { return }

        let launch: BrainLaunch
        do {
            launch = try RegattaBrainLaunch.makeClaude()
        } catch {
            status = .failed(error.localizedDescription)
            toasts.error(
                String(localized: "regatta.toast.brain.startFailed.title", defaultValue: "Brain couldn't start"),
                error.localizedDescription
            )
            return
        }

        let newSession = BrainSession(launch: launch)
        session = newSession

        // Start the session on a Task since `BrainSession.start()` is actor-isolated.
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream: AsyncStream<BrainEvent>
            do {
                stream = try await newSession.start()
            } catch {
                self.status = .failed(error.localizedDescription)
                self.session = nil
                self.toasts.error(
                    String(localized: "regatta.toast.brain.startFailed.title", defaultValue: "Brain couldn't start"),
                    error.localizedDescription
                )
                return
            }
            for await event in stream {
                guard !Task.isCancelled else { break }
                self.handle(event)
            }
        }
    }

    /// Sends a user message to the brain. Trims whitespace; ignores blank input.
    ///
    /// If ``attachedContext`` is set, a compact `[context]` block is prepended
    /// to the message text so the brain knows the active repo, branch, and PR.
    /// The ``attachedContext`` is NOT cleared after sending — the user removes
    /// it explicitly via the chip's dismiss button.
    ///
    /// The session owns the transcript. After `send` returns, ``messages`` is
    /// refreshed from the actor so the user bubble and subsequent assistant
    /// reply appear in order.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }
        status = .thinking
        let payload = messagePayload(for: trimmed, context: attachedContext)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await session.send(payload)
            } catch {
                self.toasts.error(
                    String(localized: "regatta.toast.brain.sendFailed.title", defaultValue: "Couldn't send to Brain"),
                    error.localizedDescription
                )
            }
            // Re-pull the transcript from the session to stay authoritative.
            let pulled = await session.messages()
            self.messages = pulled
        }
    }

    // MARK: - Private helpers

    /// Builds the final string sent to the brain, optionally prepending an
    /// attached-context block.
    ///
    /// - Parameters:
    ///   - text: The trimmed user message.
    ///   - context: The attached workspace context, or `nil`.
    /// - Returns: The text to pass to the brain session.
    private func messagePayload(for text: String, context: AttachedTabContext?) -> String {
        guard let ctx = context else { return text }
        var parts: [String] = []
        parts.append("repo: \(ctx.currentDirectory)")
        if let branch = ctx.gitBranch {
            parts.append("branch: \(branch)")
        }
        if let pr = ctx.pullRequest {
            parts.append("PR: #\(pr.number) (\(pr.label))")
        }
        let block = "[context] \(parts.joined(separator: ", "))"
        return "\(block)\n\n\(text)"
    }

    /// Cancels the event-consuming task and terminates the subprocess. Idempotent.
    func shutdown() {
        eventTask?.cancel()
        eventTask = nil
        guard let session else { return }
        self.session = nil
        Task { await session.stop() }
    }

    // MARK: - Private event handler

    private func handle(_ event: BrainEvent) {
        switch event {
        case .assistantDelta:
            // Mirror the actor's authoritative transcript on every delta so
            // cross-turn corruption is impossible (no local optimistic concat).
            Task {
                guard let session = self.session else { return }
                self.messages = await session.messages()
            }
        case .turnCompleted:
            // Re-pull so the final assembled turn is reflected accurately.
            Task {
                guard let session = self.session else { return }
                self.messages = await session.messages()
            }
        case .status(let s):
            status = s
            // A turn that ends in `.failed` (e.g. an API-error `result`) must
            // never be silent — surface it as a toast.
            if case .failed(let detail) = s {
                toasts.error(
                    String(localized: "regatta.toast.brain.turnFailed.title", defaultValue: "Brain hit an error"),
                    detail
                )
            }
        case .exited(let code):
            status = .exited(code)
            // The subprocess died. A non-zero exit is an error; a zero exit
            // (e.g. the user-driven shutdown) is not surfaced.
            if code != 0 {
                toasts.error(
                    String(localized: "regatta.toast.brain.exited.title", defaultValue: "Brain stopped unexpectedly"),
                    String(
                        localized: "regatta.toast.brain.exited.message",
                        defaultValue: "The brain process exited with code \(code)."
                    )
                )
            }
        }
    }
}
