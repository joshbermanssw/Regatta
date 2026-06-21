import Foundation
import Testing
import RegattaCore
import RegattaFleet

/// Tests that the persisted enums decode tolerantly: an unknown/added case (such
/// as one introduced by issue #35's parallel error-handling work) decodes to a
/// safe fallback rather than throwing, so a newer snapshot still loads.
@Suite struct TolerantDecodeTests {

    private let decoder = JSONDecoder()

    @Test func unknownWorkerStatusDecodesToInterrupted() throws {
        // A genuinely-unknown future kind falls back to the neutral restore state.
        let json = Data(#"{"kind":"hibernating"}"#.utf8)
        let status = try decoder.decode(WorkerStatus.self, from: json)
        #expect(status == .interrupted)
    }

    /// After the #35 reconcile, `blocked` is a first-class case and must decode to
    /// `.blocked` (with its reason), not fall back to `.interrupted`.
    @Test func blockedWorkerStatusDecodesToBlocked() throws {
        let json = Data(#"{"kind":"blocked","reason":"worktree conflict"}"#.utf8)
        let status = try decoder.decode(WorkerStatus.self, from: json)
        #expect(status == .blocked("worktree conflict"))
    }

    @Test func unknownLoopStatusDecodesToIdle() throws {
        let json = Data(#"{"kind":"paused"}"#.utf8)
        let status = try decoder.decode(RegattaLoopStatus.self, from: json)
        #expect(status == .idle)
    }

    @Test func unknownStopReasonDecodesToManualStop() throws {
        let json = Data(#""quotaExceeded""#.utf8)
        let reason = try decoder.decode(RegattaLoopStopReason.self, from: json)
        #expect(reason == .manualStop)
    }

    @Test func unknownStopConditionDecodesToManual() throws {
        let json = Data(#"{"kind":"judged"}"#.utf8)
        let condition = try decoder.decode(RegattaLoopStopCondition.self, from: json)
        #expect(condition == .manual)
    }

    @Test func unknownOutcomeKindDecodesToProgressed() throws {
        let json = Data(#"{"kind":"deferred","summary":"x","tokensUsed":3}"#.utf8)
        let outcome = try decoder.decode(RegattaLoopOutcome.self, from: json)
        #expect(outcome.kind == .progressed)
        #expect(outcome.summary == "x")
        #expect(outcome.tokensUsed == 3)
    }

    @Test func unknownShepherdPhaseDecodesToStarting() throws {
        // A genuinely-unknown future kind falls back to `.starting`.
        let json = Data(#"{"kind":"hibernating"}"#.utf8)
        let phase = try decoder.decode(ShepherdPollPhase.self, from: json)
        #expect(phase == .starting)
    }

    /// After the #35 reconcile, `paused` is a first-class case carrying a backoff
    /// `Duration` (serialized as seconds), and must decode to `.paused`.
    @Test func pausedShepherdPhaseDecodesToPaused() throws {
        let json = Data(#"{"kind":"paused","message":"rate limited","retryAfterSeconds":30}"#.utf8)
        let phase = try decoder.decode(ShepherdPollPhase.self, from: json)
        #expect(phase == .paused(reason: "rate limited", retryAfter: .seconds(30)))
    }

    /// A pre-#35 `paused` snapshot missing `retryAfterSeconds` still decodes (the
    /// backoff defaults to zero) rather than throwing.
    @Test func pausedShepherdPhaseToleratesMissingBackoff() throws {
        let json = Data(#"{"kind":"paused","message":"rate limited"}"#.utf8)
        let phase = try decoder.decode(ShepherdPollPhase.self, from: json)
        #expect(phase == .paused(reason: "rate limited", retryAfter: .seconds(0)))
    }
}
