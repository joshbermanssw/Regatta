import Foundation
import Testing
import RegattaFleet
import RegattaGitHub

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests for ``RegattaHandoffResolver``: the decision that turns a workspace
/// context (with cmux's often-`nil` PR detection) into a definite handoff outcome,
/// including the `gh` branch→PR fallback. The `gh` seam is stubbed, so no process
/// spawns and every branch is asserted deterministically.
@Suite("RegattaHandoffResolver")
struct RegattaHandoffResolverTests {

    @Test("nil context resolves to noContext")
    func nilContext() async {
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .success("")))
        let outcome = await resolver.resolve(context: nil)
        #expect(outcome == .noContext)
    }

    @Test("context PR is used directly without calling gh")
    func contextPRFastPath() async {
        let stub = StubRunner(result: .failure(.timedOut))
        let resolver = RegattaHandoffResolver(runner: stub)
        let ctx = AttachedTabContext(
            currentDirectory: "/tmp/repo",
            gitBranch: "feature",
            pullRequest: AttachedTabPullRequest(number: 7, label: "joshbermanssw/regatta")
        )
        let outcome = await resolver.resolve(context: ctx)
        #expect(outcome == .resolved(PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 7)))
        #expect(stub.callCount == 0) // fast path never shells out
    }

    @Test("nil context PR + gh resolving the branch PR yields resolved")
    func ghFallbackResolves() async {
        let json = """
        {"number": 42, "headRepository": {"name": "Regatta"}, "headRepositoryOwner": {"login": "JoshBermanSSW"}}
        """
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .success(json)))
        let ctx = AttachedTabContext(currentDirectory: "/tmp/repo", gitBranch: "feature", pullRequest: nil)
        let outcome = await resolver.resolve(context: ctx)
        // PullRequestRef lowercases owner/repo for case-insensitive identity.
        #expect(outcome == .resolved(PullRequestRef(owner: "joshbermanssw", repo: "regatta", number: 42)))
    }

    @Test("nil context PR + gh reporting no PR yields noPullRequest with branch")
    func ghFallbackNoPR() async {
        let err = GitHubCommandError.nonZeroExit(exitStatus: 1, stderr: "no pull requests found for branch \"feature\"")
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .failure(err)))
        let ctx = AttachedTabContext(currentDirectory: "/tmp/repo", gitBranch: "feature", pullRequest: nil)
        let outcome = await resolver.resolve(context: ctx)
        #expect(outcome == .noPullRequest(branch: "feature"))
    }

    @Test("gh auth failure yields authFailure")
    func ghAuthFailure() async {
        let err = GitHubCommandError.nonZeroExit(exitStatus: 1, stderr: "gh auth login required: not logged in")
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .failure(err)))
        let ctx = AttachedTabContext(currentDirectory: "/tmp/repo", gitBranch: "feature", pullRequest: nil)
        let outcome = await resolver.resolve(context: ctx)
        #expect(outcome == .authFailure)
    }

    @Test("gh timeout yields a generic failure")
    func ghTimeout() async {
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .failure(.timedOut)))
        let ctx = AttachedTabContext(currentDirectory: "/tmp/repo", gitBranch: "feature", pullRequest: nil)
        let outcome = await resolver.resolve(context: ctx)
        if case .failure = outcome { } else { Issue.record("expected .failure, got \(outcome)") }
    }

    @Test("empty current directory resolves to noContext")
    func emptyDirectory() async {
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .success("")))
        let ctx = AttachedTabContext(currentDirectory: "   ", gitBranch: "feature", pullRequest: nil)
        let outcome = await resolver.resolve(context: ctx)
        #expect(outcome == .noContext)
    }

    @Test("malformed gh JSON yields noPullRequest")
    func malformedJSON() async {
        let resolver = RegattaHandoffResolver(runner: StubRunner(result: .success("{not json")))
        let ctx = AttachedTabContext(currentDirectory: "/tmp/repo", gitBranch: "feature", pullRequest: nil)
        let outcome = await resolver.resolve(context: ctx)
        #expect(outcome == .noPullRequest(branch: "feature"))
    }
}

/// A stub `gh` runner returning a canned result, counting calls so tests can
/// assert the fast path never shells out.
private final class StubRunner: RegattaWorkspaceCommandRunning, @unchecked Sendable {
    // @unchecked: callCount is mutated only from the resolver's single awaited
    // call in these serial tests; no concurrent access.
    private let result: Result<String, GitHubCommandError>
    private(set) var callCount = 0

    init(result: Result<String, GitHubCommandError>) {
        self.result = result
    }

    func run(_ args: [String], in directory: String) async throws -> String {
        callCount += 1
        switch result {
        case .success(let output): return output
        case .failure(let error): throw error
        }
    }
}
