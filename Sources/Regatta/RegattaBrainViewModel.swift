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

    // MARK: - Private non-observable state

    /// The actor that owns the subprocess. `@ObservationIgnored` because it is
    /// an internal resource handle, not UI-observable.
    @ObservationIgnored
    private var session: BrainSession?

    /// The structured `Task` consuming the ``BrainEvent`` stream.
    @ObservationIgnored
    private var eventTask: Task<Void, Never>?

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
    /// The session owns the transcript. After `send` returns, ``messages`` is
    /// refreshed from the actor so the user bubble and subsequent assistant
    /// reply appear in order.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return }
        status = .thinking
        Task {
            try? await session.send(trimmed)
            // Re-pull the transcript from the session to stay authoritative.
            let pulled = await session.messages()
            self.messages = pulled
        }
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
        case .assistantDelta(let chunk):
            // Append to the last assistant message in our local array so the
            // streaming text appears without a round-trip to the actor.
            if let lastIndex = messages.indices.last, messages[lastIndex].role == .assistant {
                messages[lastIndex].text += chunk
            } else {
                // A new assistant turn started — pull the full transcript once
                // so we pick up the message the actor just appended.
                Task {
                    guard let session = self.session else { return }
                    self.messages = await session.messages()
                }
            }
        case .turnCompleted:
            // Re-pull so any in-flight delta that arrived after the last event
            // is captured accurately.
            Task {
                guard let session = self.session else { return }
                self.messages = await session.messages()
            }
        case .status(let s):
            status = s
        case .exited(let code):
            status = .exited(code)
        }
    }
}
