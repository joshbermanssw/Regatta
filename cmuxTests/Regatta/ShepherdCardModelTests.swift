import Foundation
import Testing
import RegattaFleet
import RegattaGitHub

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``ShepherdCardModel`` — the pure projection of a shepherd's state
/// into the PR shepherd card's sections (issue #33).
@Suite("ShepherdCardModel projection")
struct ShepherdCardModelTests {

    // MARK: - Fixtures

    private func ref(_ number: Int = 1) -> PullRequestRef {
        PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: number)
    }

    private func check(_ name: String, status: String, conclusion: String?) -> PRCheck {
        PRCheck(name: name, status: status, conclusion: conclusion, detailsURL: nil)
    }

    private func thread(
        id: String,
        resolved: Bool = false,
        outdated: Bool = false,
        comments: [ReviewComment] = []
    ) -> ReviewThread {
        ReviewThread(id: id, isResolved: resolved, isOutdated: outdated, path: "File.swift", comments: comments)
    }

    private func comment(_ author: String) -> ReviewComment {
        ReviewComment(id: UUID().uuidString, body: "body", author: author, url: "https://example.com")
    }

    // MARK: - CI rollup

    @Test("rollup is none when no checks reported")
    func rollupNone() {
        let state = ShepherdState(pullRequest: ref(), phase: .watching)
        let model = ShepherdCardModel(state: state)
        #expect(model.ciRollup == .none)
        #expect(model.checkRows.isEmpty)
    }

    @Test("rollup is failing when any check failed")
    func rollupFailing() {
        let summary = PRCheckSummary(checks: [
            check("build", status: "COMPLETED", conclusion: "SUCCESS"),
            check("test", status: "COMPLETED", conclusion: "FAILURE"),
        ])
        let state = ShepherdState(pullRequest: ref(), phase: .watching, checks: summary)
        let model = ShepherdCardModel(state: state)
        #expect(model.ciRollup == .failing)
    }

    @Test("rollup is passing only when all checks succeeded")
    func rollupPassing() {
        let summary = PRCheckSummary(checks: [
            check("build", status: "COMPLETED", conclusion: "SUCCESS"),
            check("test", status: "COMPLETED", conclusion: "SUCCESS"),
        ])
        let state = ShepherdState(pullRequest: ref(), phase: .watching, checks: summary)
        let model = ShepherdCardModel(state: state)
        #expect(model.ciRollup == .passing)
    }

    @Test("rollup is running while a check is in progress")
    func rollupRunning() {
        let summary = PRCheckSummary(checks: [
            check("build", status: "IN_PROGRESS", conclusion: nil),
        ])
        let state = ShepherdState(pullRequest: ref(), phase: .watching, checks: summary)
        let model = ShepherdCardModel(state: state)
        #expect(model.ciRollup == .running)
    }

    // MARK: - Check rows

    @Test("check rows carry per-check status mapping")
    func checkRowStatuses() {
        let summary = PRCheckSummary(checks: [
            check("pass", status: "COMPLETED", conclusion: "SUCCESS"),
            check("skip", status: "COMPLETED", conclusion: "SKIPPED"),
            check("fail", status: "COMPLETED", conclusion: "FAILURE"),
            check("run", status: "QUEUED", conclusion: nil),
        ])
        let state = ShepherdState(pullRequest: ref(), phase: .watching, checks: summary)
        let model = ShepherdCardModel(state: state)
        #expect(model.checkRows.count == 4)
        #expect(model.checkRows[0].status == .passed)
        #expect(model.checkRows[1].status == .passed) // SKIPPED treated as non-failing
        #expect(model.checkRows[2].status == .failed)
        #expect(model.checkRows[3].status == .running)
    }

    // MARK: - Thread status

    @Test("resolved or outdated threads project as resolved")
    func threadResolved() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            reviewThreads: [
                thread(id: "a", resolved: true),
                thread(id: "b", outdated: true),
            ]
        )
        let model = ShepherdCardModel(state: state)
        #expect(model.threadRows.allSatisfy { $0.status == .resolved })
        #expect(model.openThreadCount == 0)
    }

    @Test("open thread with no reply projects as addressing")
    func threadAddressing() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            reviewThreads: [thread(id: "a", comments: [comment("reviewer")])]
        )
        let model = ShepherdCardModel(state: state)
        #expect(model.threadRows.first?.status == .addressing)
        #expect(model.openThreadCount == 1)
    }

    @Test("open thread the shepherd replied to projects as replied")
    func threadReplied() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            reviewThreads: [
                thread(id: "a", comments: [comment("reviewer"), comment("regatta-bot")]),
            ]
        )
        let model = ShepherdCardModel(state: state, shepherdLogin: "regatta-bot")
        #expect(model.threadRows.first?.status == .replied)
    }

    @Test("reply by someone other than the shepherd is not counted as replied")
    func threadOtherAuthorNotReplied() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            reviewThreads: [
                thread(id: "a", comments: [comment("reviewer"), comment("another-human")]),
            ]
        )
        let model = ShepherdCardModel(state: state, shepherdLogin: "regatta-bot")
        #expect(model.threadRows.first?.status == .addressing)
    }

    // MARK: - Activity log ordering

    @Test("activity log is sorted newest first")
    func activitySortedNewestFirst() {
        let now = Date()
        let entries = [
            ShepherdActivityEntry(timestamp: now.addingTimeInterval(-30), kind: .push, summary: "older"),
            ShepherdActivityEntry(timestamp: now, kind: .reply, summary: "newest"),
            ShepherdActivityEntry(timestamp: now.addingTimeInterval(-10), kind: .resolve, summary: "middle"),
        ]
        let state = ShepherdState(pullRequest: ref(), phase: .watching)
        let model = ShepherdCardModel(state: state, activity: entries)
        #expect(model.activity.map(\.summary) == ["newest", "middle", "older"])
    }

    // MARK: - Section composition / pass-through

    @Test("pending actions and fix loop pass through to the model")
    func pendingAndFixLoopPassThrough() {
        let pr = ref()
        let pending = [PendingAction(pullRequest: pr, kind: .push, summary: "Push fix")]
        let loop = ShepherdFixLoopStatus(phase: .running, failingCheck: "build", attempt: 2)
        let state = ShepherdState(pullRequest: pr, phase: .watching)
        let model = ShepherdCardModel(state: state, pending: pending, fixLoop: loop)
        #expect(model.pending.count == 1)
        #expect(model.fixLoop?.attempt == 2)
        #expect(model.fixLoop?.phase == .running)
    }

    @Test("no fix loop by default (the #30 seam is empty in this base)")
    func noFixLoopByDefault() {
        let state = ShepherdState(pullRequest: ref(), phase: .watching)
        let model = ShepherdCardModel(state: state)
        #expect(model.fixLoop == nil)
    }

    // MARK: - Conversation comments

    private func conversationComment(_ id: String, author: String, body: String = "please fix") -> PRConversationComment {
        PRConversationComment(
            id: id,
            body: body,
            author: author,
            url: "https://example.com/\(id)",
            createdAt: "2026-06-21T12:00:00Z"
        )
    }

    @Test("conversation comments project into rows")
    func conversationRowsProject() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            conversationComments: [
                conversationComment("C1", author: "alice"),
                conversationComment("C2", author: "bob"),
            ]
        )
        let model = ShepherdCardModel(state: state)
        #expect(model.conversationRows.map(\.id) == ["C1", "C2"])
        #expect(model.conversationRows.first?.author == "alice")
        #expect(model.conversationCount == 2)
    }

    @Test("the shepherd's own replies are marked self and excluded from the actionable count")
    func selfCommentsMarkedAndExcluded() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            conversationComments: [
                conversationComment("C1", author: "alice"),
                conversationComment("MINE", author: "shepherd-bot"),
            ]
        )
        let model = ShepherdCardModel(state: state, shepherdLogin: "shepherd-bot")
        let mine = model.conversationRows.first { $0.id == "MINE" }
        #expect(mine?.isSelf == true)
        // Only the non-self comment counts toward the actionable conversation count.
        #expect(model.conversationCount == 1)
    }

    // MARK: - Reviews (review summaries)

    private func review(
        _ id: String,
        author: String,
        state: PRReview.State,
        body: String = "summary"
    ) -> PRReview {
        PRReview(id: id, author: author, state: state, body: body, submittedAt: "2026-06-21T12:00:00Z")
    }

    @Test("reviews project into rows with verdict badges")
    func reviewRowsProject() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            reviews: [
                review("R1", author: "alice", state: .approved, body: "nice work, one nit"),
                review("R2", author: "bob", state: .changesRequested, body: "fix this"),
                review("R3", author: "carol", state: .commented, body: "question?"),
            ]
        )
        let model = ShepherdCardModel(state: state)
        #expect(model.reviewRows.map(\.id) == ["R1", "R2", "R3"])
        #expect(model.reviewRows.map(\.badge) == [.approved, .changesRequested, .commented])
        #expect(model.reviewRows.first?.author == "alice")
        #expect(model.reviewCount == 3)
    }

    @Test("the shepherd's own reviews are marked self and excluded from the actionable count")
    func selfReviewsMarkedAndExcluded() {
        let state = ShepherdState(
            pullRequest: ref(),
            phase: .watching,
            reviews: [
                review("R1", author: "alice", state: .changesRequested, body: "fix this"),
                review("MINE", author: "shepherd-bot", state: .commented, body: "addressed"),
            ]
        )
        let model = ShepherdCardModel(state: state, shepherdLogin: "shepherd-bot")
        let mine = model.reviewRows.first { $0.id == "MINE" }
        #expect(mine?.isSelf == true)
        #expect(model.reviewCount == 1)
    }
}
