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
        let json = Data(#"{"kind":"blocked"}"#.utf8)
        let status = try decoder.decode(WorkerStatus.self, from: json)
        #expect(status == .interrupted)
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
        let json = Data(#"{"kind":"paused"}"#.utf8)
        let phase = try decoder.decode(ShepherdPollPhase.self, from: json)
        #expect(phase == .starting)
    }
}
