import Foundation
import Testing
import RegattaCore
@testable import RegattaBrain

/// Tests for ``RegattaBrainLoopJudge`` — the brain-backed ``RegattaLoopJudge``
/// for issue #21.
///
/// Pure parsing/prompt logic is asserted directly. The full session pipeline is
/// exercised through fake stream-json agents (`fake-judge.sh` for the
/// affirmative path, `fake-claude.sh` for the echo/negative path) — no real CLI
/// or network. Serialized so concurrent process spawns can't cross-inherit pipe
/// FDs.
@Suite(.serialized)
struct RegattaBrainLoopJudgeTests {

    private func launch(forResource resource: String) throws -> BrainLaunch {
        let url = try #require(
            Bundle.module.url(forResource: resource, withExtension: "sh"),
            "\(resource).sh resource missing from test bundle"
        )
        return BrainLaunch(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [url.path],
            environment: ["PATH": "/usr/bin:/bin"]
        )
    }

    private func request(iteration: Int = 0) -> RegattaJudgeRequest {
        RegattaJudgeRequest(
            goal: "make the tests pass",
            iterationIndex: iteration,
            latestSummary: "ran the suite",
            priorSummaries: []
        )
    }

    // MARK: - Prompt composition

    @Test func composePromptIncludesGoalAndSummaries() {
        let prompt = RegattaBrainLoopJudge.composePrompt(
            RegattaJudgeRequest(
                goal: "ship the feature",
                iterationIndex: 3,
                latestSummary: "all green",
                priorSummaries: ["a", "b"]
            )
        )
        #expect(prompt.contains("ship the feature"))
        #expect(prompt.contains("#3"))
        #expect(prompt.contains("all green"))
        #expect(prompt.contains("a; b"))
        #expect(prompt.contains("YES"))
    }

    // MARK: - Verdict parsing

    @Test(arguments: [
        ("YES — done", true),
        ("yes, all tests pass", true),
        ("DONE", true),
        ("Complete now", true),
        ("NO, still failing", false),
        ("not yet", false),
        ("echo: You are judging…", false),
    ])
    func parseGoalMetReadsLeadingToken(reply: String, expected: Bool) {
        #expect(RegattaBrainLoopJudge.parseGoalMet(reply) == expected)
    }

    // MARK: - Affirmative path through a fake brain (no network)

    @Test func affirmativeBrainReplyYieldsGoalMetVerdict() async throws {
        let session = BrainSession(launch: try launch(forResource: "fake-judge"))
        let judge = RegattaBrainLoopJudge(session: session)

        let verdict = try await judge.judge(request())

        #expect(verdict.goalMet == true)
        #expect(verdict.iterationIndex == 0)
        #expect(verdict.reasoning.contains("YES"))
        #expect(verdict.prompt.contains("make the tests pass"))

        await session.stop()
    }

    // MARK: - Negative path through the echo fake brain

    /// `fake-claude.sh` echoes the prompt back ("echo: …"), whose leading token
    /// is "echo" → not met. Proves the full send → drain → parse pipeline and
    /// the negative verdict path through a real ``BrainSession``.
    @Test func nonAffirmativeBrainReplyYieldsNotMetVerdict() async throws {
        let session = BrainSession(launch: try launch(forResource: "fake-claude"))
        let judge = RegattaBrainLoopJudge(session: session)

        let verdict = try await judge.judge(request(iteration: 2))

        #expect(verdict.goalMet == false)
        #expect(verdict.iterationIndex == 2)
        #expect(verdict.reasoning.contains("echo:"))

        await session.stop()
    }

    // MARK: - Persistent session reused across iterations

    /// The judge starts the session once and reuses it across iterations — two
    /// successive judgments each get a verdict over the same session.
    @Test func reusesSessionAcrossIterations() async throws {
        let session = BrainSession(launch: try launch(forResource: "fake-judge"))
        let judge = RegattaBrainLoopJudge(session: session)

        let first = try await judge.judge(request(iteration: 0))
        let second = try await judge.judge(request(iteration: 1))

        #expect(first.goalMet == true)
        #expect(second.goalMet == true)
        #expect(second.iterationIndex == 1)

        await session.stop()
    }

    // MARK: - Conforms to the RegattaCore seam

    /// The brain judge is usable wherever an `any RegattaLoopJudge` is required —
    /// the dependency-inversion seam the LLM-judged condition depends on.
    @Test func conformsToLoopJudgeSeam() async throws {
        let session = BrainSession(launch: try launch(forResource: "fake-judge"))
        let judge: any RegattaLoopJudge = RegattaBrainLoopJudge(session: session)

        let verdict = try await judge.judge(request())
        #expect(verdict.goalMet == true)

        await session.stop()
    }
}
