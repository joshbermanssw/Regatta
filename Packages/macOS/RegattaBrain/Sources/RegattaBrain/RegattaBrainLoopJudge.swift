import Foundation
public import RegattaCore

/// The production ``RegattaLoopJudge`` for issue #21: it asks the persistent
/// Claude Code brain session (#12) whether a loop's goal has been met.
///
/// This is the brain-backed conformer of `RegattaCore`'s judge seam. It lives in
/// `RegattaBrain` (a Service layer that may depend on `RegattaCore`), so
/// `RegattaCore` itself never imports the brain — the dependency points the
/// right way. `RegattaCore`'s loop conditions depend only on the `any
/// RegattaLoopJudge` protocol, and tests inject a stub instead of this type, so
/// the LLM-judged condition is exercised without a live API call.
///
/// ## How it judges
/// The brain session is *persistent*: it is started once (on the first verdict)
/// and reused across every iteration's judgment. For each request the judge
/// composes a yes/no completion prompt (``composePrompt``), sends it over the
/// session, drains that turn (until `.turnCompleted`), and parses the leading
/// token: an affirmative answer (`YES` / `DONE` / `COMPLETE`) is a "goal met"
/// verdict. The exact prompt and the brain's full reply are carried back in the
/// ``RegattaJudgeVerdict`` so the loop journal records why it stopped.
///
/// All mutable state (the started stream) lives in this actor, so concurrent
/// `judge(_:)` calls are serialized and the session is started exactly once.
///
/// ## Testability
/// The session is injected. Tests can pass a ``BrainSession`` wired to the
/// `fake-claude.sh` stream-JSON emitter (no network), but the
/// ``RegattaLoopJudge`` protocol is the more common seam — most loop tests stub
/// the verdict directly and never construct this type.
public actor RegattaBrainLoopJudge: RegattaLoopJudge {
    private let session: BrainSession
    private let perVerdictTimeout: Duration
    private var events: IteratorBox?

    /// Creates a brain-backed judge over a brain session.
    ///
    /// - Parameters:
    ///   - session: The persistent brain session to ask. The judge starts it on
    ///     first use; the caller owns ``BrainSession/stop()``.
    ///   - perVerdictTimeout: How long to wait for one verdict's turn to
    ///     complete before throwing ``RegattaBrainJudgeError/timedOut``. Default
    ///     is 120 seconds.
    public init(session: BrainSession, perVerdictTimeout: Duration = .seconds(120)) {
        self.session = session
        self.perVerdictTimeout = perVerdictTimeout
    }

    /// Composes the yes/no judging prompt for a request.
    ///
    /// Exposed so callers and tests can see (and assert on) the exact text the
    /// brain is asked — the same string is recorded in the verdict.
    ///
    /// - Parameter request: The completion request to judge.
    /// - Returns: The prompt text.
    public static func composePrompt(_ request: RegattaJudgeRequest) -> String {
        var lines: [String] = []
        lines.append("You are judging whether a coding loop has met its goal.")
        lines.append("Goal: \(request.goal)")
        lines.append("Latest iteration (#\(request.iterationIndex)) summary: \(request.latestSummary)")
        if !request.priorSummaries.isEmpty {
            lines.append("Prior iterations: \(request.priorSummaries.joined(separator: "; "))")
        }
        lines.append(
            "Answer on the first line with YES if the goal is fully met, or NO if more work is needed, then briefly explain why."
        )
        return lines.joined(separator: "\n")
    }

    /// Asks the brain whether the goal is met and parses its reply.
    ///
    /// - Parameter request: The completion request.
    /// - Returns: The verdict, carrying the prompt and the brain's reply.
    /// - Throws: ``RegattaBrainJudgeError`` if the brain produces no answer or
    ///   the turn times out; any error from ``BrainSession`` I/O.
    public func judge(_ request: RegattaJudgeRequest) async throws -> RegattaJudgeVerdict {
        let prompt = Self.composePrompt(request)
        try await startIfNeeded()
        try await session.send(prompt)

        let reply = try await drainAssistantTurn()
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RegattaBrainJudgeError.emptyVerdict
        }

        return RegattaJudgeVerdict(
            iterationIndex: request.iterationIndex,
            goalMet: Self.parseGoalMet(trimmed),
            prompt: prompt,
            reasoning: trimmed
        )
    }

    /// Parses an affirmative verdict from the brain's reply.
    ///
    /// Looks at the first non-empty line's leading word for a `YES` / `DONE` /
    /// `COMPLETE` token; anything else (including `NO`) is "not yet met".
    static func parseGoalMet(_ reply: String) -> Bool {
        let firstLine = reply
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? reply
        let leadingWord = firstLine
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map { String($0).uppercased() } ?? ""
        switch leadingWord {
        case "YES", "DONE", "COMPLETE", "COMPLETED":
            return true
        default:
            return false
        }
    }

    /// Starts the session once and caches its event iterator.
    private func startIfNeeded() async throws {
        guard events == nil else { return }
        let created = try await session.start()
        events = IteratorBox(created.makeAsyncIterator())
    }

    /// Reads assistant text deltas from the shared iterator until the turn
    /// completes (or the per-verdict deadline fires between events).
    private func drainAssistantTurn() async throws -> String {
        guard let events else { return "" }
        let deadline = ContinuousClock.now.advanced(by: perVerdictTimeout)
        var assembled = ""
        while ContinuousClock.now < deadline {
            guard let event = await events.next() else {
                return assembled
            }
            switch event {
            case .assistantDelta(let text):
                assembled += text
            case .turnCompleted, .exited:
                return assembled
            case .status:
                continue
            }
        }
        throw RegattaBrainJudgeError.timedOut
    }
}

/// A reference wrapper around an ``AsyncStream`` iterator so an actor can hold
/// and mutate a single long-lived iterator across calls.
///
/// `AsyncStream.Iterator.next()` is `mutating`, which a `let`-captured actor
/// property cannot call; boxing it in a reference type lets the actor advance
/// one shared iterator across successive ``RegattaBrainLoopJudge/judge(_:)``
/// turns. Confined to the owning actor, so no extra synchronization is needed.
private final class IteratorBox: @unchecked Sendable {
    // Mutated only while the owning actor is executing; the actor serializes all
    // access, so the unchecked conformance is sound.
    private var iterator: AsyncStream<BrainEvent>.Iterator

    init(_ iterator: AsyncStream<BrainEvent>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> BrainEvent? {
        await iterator.next()
    }
}

/// Errors thrown by ``RegattaBrainLoopJudge``.
public enum RegattaBrainJudgeError: Error, Equatable, Sendable {
    /// The brain produced no answer for the verdict.
    case emptyVerdict
    /// The verdict turn did not complete within the configured timeout.
    case timedOut
}
