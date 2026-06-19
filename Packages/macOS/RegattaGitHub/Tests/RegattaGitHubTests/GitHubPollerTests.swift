import Testing
@testable import RegattaGitHub

// MARK: - Check Statuses

@Suite("GitHubPoller — fetchChecks")
struct GitHubPollerChecksTests {
    // MARK: Happy path

    @Test("parses a typical statusCheckRollup with mixed statuses")
    func parsesTypicalStatusCheckRollup() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.statusCheckRollup)])
        let poller = GitHubPoller(commandRunner: fake)
        let checks = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 28)

        #expect(checks.count == 3)

        let build = try #require(checks.first { $0.name == "build" })
        #expect(build.status == "COMPLETED")
        #expect(build.conclusion == "SUCCESS")
        #expect(build.detailsURL == "https://github.com/manaflow-ai/cmux/actions/runs/1234/jobs/5678")

        let lint = try #require(checks.first { $0.name == "lint" })
        #expect(lint.status == "IN_PROGRESS")
        #expect(lint.conclusion == nil)
    }

    @Test("parses a failed check correctly")
    func parsesFailedCheck() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.statusCheckRollupWithFailure)])
        let poller = GitHubPoller(commandRunner: fake)
        let checks = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 28)

        #expect(checks.count == 2)
        let failedCheck = try #require(checks.first { $0.name == "test (macos-14)" })
        #expect(failedCheck.conclusion == "FAILURE")
    }

    // MARK: Empty / null cases

    @Test("returns empty array when statusCheckRollup is empty")
    func returnsEmptyArrayForEmptyRollup() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.statusCheckRollupEmpty)])
        let poller = GitHubPoller(commandRunner: fake)
        let checks = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 1)
        #expect(checks.isEmpty)
    }

    @Test("returns empty array when statusCheckRollup is null")
    func returnsEmptyArrayForNullRollup() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.statusCheckRollupNull)])
        let poller = GitHubPoller(commandRunner: fake)
        let checks = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 1)
        #expect(checks.isEmpty)
    }

    // MARK: Commit-status entries

    @Test("normalises a legacy commit-status entry")
    func normalisesLegacyCommitStatus() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.statusCheckRollupWithCommitStatus)])
        let poller = GitHubPoller(commandRunner: fake)
        let checks = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 28)

        #expect(checks.count == 1)
        let check = try #require(checks.first)
        #expect(check.name == "ci/circleci: build")
        #expect(check.status == "COMPLETED")
        #expect(check.conclusion == "SUCCESS")
    }

    // MARK: Error cases

    @Test("throws jsonDecodingFailed for malformed JSON")
    func throwsForMalformedJSON() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.malformedJSON)])
        let poller = GitHubPoller(commandRunner: fake)
        await #expect(throws: GitHubCommandError.self) {
            _ = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 28)
        }
    }

    @Test("propagates gh command failures")
    func propagatesCommandFailure() async throws {
        let fake = FakeGitHubCommandRunner(responses: [
            .failure(.nonZeroExit(exitStatus: 1, stderr: "Could not resolve to a PullRequest"))
        ])
        let poller = GitHubPoller(commandRunner: fake)
        do {
            _ = try await poller.fetchChecks(owner: "manaflow-ai", repo: "cmux", prNumber: 99999)
            Issue.record("Expected an error but fetchChecks returned successfully")
        } catch let error as GitHubCommandError {
            if case .nonZeroExit(let status, _) = error {
                #expect(status == 1)
            } else {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }
}

// MARK: - PRCheckSummary

@Suite("PRCheckSummary computed properties")
struct PRCheckSummaryTests {
    @Test("allSucceeded is true when every check is COMPLETED + SUCCESS")
    func allSucceededWithAllSuccess() {
        let summary = PRCheckSummary(checks: [
            PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil),
            PRCheck(name: "test", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil),
        ])
        #expect(summary.allSucceeded == true)
        #expect(summary.anyFailed == false)
        #expect(summary.anyPending == false)
    }

    @Test("allSucceeded is false when any check is pending")
    func allSucceededFalseWhenPending() {
        let summary = PRCheckSummary(checks: [
            PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil),
            PRCheck(name: "lint", status: "IN_PROGRESS", conclusion: nil, detailsURL: nil),
        ])
        #expect(summary.allSucceeded == false)
        #expect(summary.anyPending == true)
    }

    @Test("anyFailed detects a FAILURE conclusion")
    func anyFailedDetectsFailure() {
        let summary = PRCheckSummary(checks: [
            PRCheck(name: "build", status: "COMPLETED", conclusion: "SUCCESS", detailsURL: nil),
            PRCheck(name: "test", status: "COMPLETED", conclusion: "FAILURE", detailsURL: nil),
        ])
        #expect(summary.anyFailed == true)
        #expect(summary.allSucceeded == false)
    }

    @Test("allSucceeded is false for an empty checks array")
    func allSucceededFalseWhenEmpty() {
        let summary = PRCheckSummary(checks: [])
        #expect(summary.allSucceeded == false)
    }
}

// MARK: - Review Threads

@Suite("GitHubPoller — fetchReviewThreads")
struct GitHubPollerReviewThreadsTests {
    // MARK: Happy path

    @Test("parses a typical review-thread response")
    func parsesTypicalReviewThreads() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.reviewThreads)])
        let poller = GitHubPoller(commandRunner: fake)
        let threads = try await poller.fetchReviewThreads(owner: "manaflow-ai", repo: "cmux", prNumber: 28)

        #expect(threads.count == 2)

        let openThread = try #require(threads.first { !$0.isResolved })
        #expect(openThread.id == "PRRT_kwDOBcDe8M5ABC123")
        #expect(openThread.isResolved == false)
        #expect(openThread.isOutdated == false)
        #expect(openThread.path == "Sources/Regatta/GitHubPoller.swift")
        #expect(openThread.comments.count == 2)

        let firstComment = try #require(openThread.comments.first)
        #expect(firstComment.author == "alice")
        #expect(firstComment.body.contains("throw unexpectedly"))

        let resolvedThread = try #require(threads.first { $0.isResolved })
        #expect(resolvedThread.id == "PRRT_kwDOBcDe8M5DEF123")
        #expect(resolvedThread.isResolved == true)
        #expect(resolvedThread.comments.count == 1)
    }

    @Test("parses an outdated review thread")
    func parsesOutdatedThread() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.reviewThreadsOutdated)])
        let poller = GitHubPoller(commandRunner: fake)
        let threads = try await poller.fetchReviewThreads(owner: "manaflow-ai", repo: "cmux", prNumber: 28)

        #expect(threads.count == 1)
        let thread = try #require(threads.first)
        #expect(thread.isOutdated == true)
        #expect(thread.isResolved == false)
    }

    // MARK: Empty case

    @Test("returns empty array when there are no review threads")
    func returnsEmptyArrayForNoThreads() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.reviewThreadsEmpty)])
        let poller = GitHubPoller(commandRunner: fake)
        let threads = try await poller.fetchReviewThreads(owner: "manaflow-ai", repo: "cmux", prNumber: 1)
        #expect(threads.isEmpty)
    }

    // MARK: Error cases

    @Test("throws jsonDecodingFailed for malformed JSON")
    func throwsForMalformedJSON() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.success(Fixtures.malformedJSON)])
        let poller = GitHubPoller(commandRunner: fake)
        await #expect(throws: GitHubCommandError.self) {
            _ = try await poller.fetchReviewThreads(owner: "manaflow-ai", repo: "cmux", prNumber: 28)
        }
    }

    @Test("propagates a timed-out error")
    func propagatesTimedOutError() async throws {
        let fake = FakeGitHubCommandRunner(responses: [.failure(.timedOut)])
        let poller = GitHubPoller(commandRunner: fake)
        do {
            _ = try await poller.fetchReviewThreads(owner: "manaflow-ai", repo: "cmux", prNumber: 28)
            Issue.record("Expected timedOut error")
        } catch let error as GitHubCommandError {
            if case .timedOut = error {
                // Pass — correct error type.
            } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}
