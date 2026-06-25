import Foundation
import Testing
import RegattaCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``WorkerStatusPresentation`` — the shared, legible projection of a
/// worker's status used by both the Fleet rail row and the Open-Fleet-grid cell.
///
/// These lock the state-legibility contract: every status maps to a plain label,
/// the right semantic category (which drives dot colour + needs-attention), and a
/// reason detail where one exists — so "Done" can never be confused with a worker
/// that actually failed or was blocked.
@Suite("WorkerStatusPresentation legibility")
struct WorkerStatusPresentationTests {

    // MARK: - Category mapping

    @Test("each status maps to its semantic category")
    func categoryMapping() {
        #expect(WorkerStatusPresentation(.queued).category == .queued)
        #expect(WorkerStatusPresentation(.running).category == .running)
        #expect(WorkerStatusPresentation(.done).category == .succeeded)
        #expect(WorkerStatusPresentation(.failed("boom")).category == .failed)
        #expect(WorkerStatusPresentation(.blocked("conflict")).category == .blocked)
        #expect(WorkerStatusPresentation(.cancelled).category == .cancelled)
        #expect(WorkerStatusPresentation(.interrupted).category == .interrupted)
    }

    // MARK: - Done is unambiguous

    @Test("Done is labelled as a success, not a bare ambiguous Done")
    func doneIsSucceeded() {
        let p = WorkerStatusPresentation(.done)
        #expect(p.category == .succeeded)
        #expect(p.needsAttention == false)
        // The label distinguishes success from a give-up: it must read as more
        // than the bare word "Done".
        #expect(p.label.contains("succeeded") || p.label != "Done")
        #expect(p.detail == nil)
    }

    // MARK: - Needs-attention semantics

    @Test("failed, blocked, and interrupted need attention; the rest do not")
    func needsAttentionSemantics() {
        #expect(WorkerStatusPresentation(.failed("x")).needsAttention)
        #expect(WorkerStatusPresentation(.blocked("x")).needsAttention)
        #expect(WorkerStatusPresentation(.interrupted).needsAttention)

        #expect(!WorkerStatusPresentation(.queued).needsAttention)
        #expect(!WorkerStatusPresentation(.running).needsAttention)
        #expect(!WorkerStatusPresentation(.done).needsAttention)
        #expect(!WorkerStatusPresentation(.cancelled).needsAttention)
    }

    // MARK: - Reason detail

    @Test("failed and blocked surface their reason as a detail line")
    func reasonDetail() {
        #expect(WorkerStatusPresentation(.failed("exit code 1")).detail == "exit code 1")
        #expect(WorkerStatusPresentation(.blocked("worktree conflict")).detail == "worktree conflict")
    }

    @Test("a whitespace-only reason collapses to no detail")
    func blankReasonHasNoDetail() {
        #expect(WorkerStatusPresentation(.failed("   \n  ")).detail == nil)
    }

    @Test("a reason with surrounding whitespace is trimmed")
    func reasonTrimmed() {
        #expect(WorkerStatusPresentation(.failed("  boom  ")).detail == "boom")
    }

    @Test("statuses without a reason have no detail")
    func noDetailWhenNoReason() {
        #expect(WorkerStatusPresentation(.queued).detail == nil)
        #expect(WorkerStatusPresentation(.running).detail == nil)
        #expect(WorkerStatusPresentation(.cancelled).detail == nil)
        #expect(WorkerStatusPresentation(.interrupted).detail == nil)
    }

    // MARK: - Accessibility summary

    @Test("accessibility summary combines label and detail when present")
    func accessibilitySummaryCombines() {
        let p = WorkerStatusPresentation(.failed("exit code 1"))
        #expect(p.accessibilitySummary == "\(p.label): exit code 1")
    }

    @Test("accessibility summary is just the label when there is no detail")
    func accessibilitySummaryLabelOnly() {
        let p = WorkerStatusPresentation(.running)
        #expect(p.accessibilitySummary == p.label)
    }

    // MARK: - Label non-emptiness

    @Test("every status produces a non-empty label")
    func everyLabelNonEmpty() {
        let statuses: [WorkerStatus] = [
            .queued, .running, .done,
            .failed("x"), .blocked("x"), .cancelled, .interrupted,
        ]
        for status in statuses {
            #expect(!WorkerStatusPresentation(status).label.isEmpty)
        }
    }
}
