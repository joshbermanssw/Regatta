import Foundation
import Testing
@testable import RegattaBrain

/// Behavioral tests for the persistent streaming brain session, exercised
/// through a fake stream-json agent process (`fake-claude.sh`) — no real CLI or
/// network. Serialized so concurrent process spawns can't cross-inherit pipe
/// FDs (belt-and-suspenders alongside the close-on-exec in BrainSession).
@Suite(.serialized)
struct BrainSessionTests {

    /// Resolves the bundled fake agent and builds a launch that runs it via bash
    /// (so the resource's executable bit is irrelevant).
    private func fakeLaunch(resource: String = "fake-claude") throws -> BrainLaunch {
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

    /// Drives one assistant turn from a manual iterator: collect deltas until
    /// `.turnCompleted`. Does NOT await stream end (the process is persistent).
    private func nextTurn(
        _ iterator: inout AsyncStream<BrainEvent>.Iterator
    ) async -> String {
        var text = ""
        while let event = await iterator.next() {
            switch event {
            case .assistantDelta(let delta):
                text += delta
            case .turnCompleted:
                return text
            default:
                break
            }
        }
        return text
    }

    @Test func sendReceivesStreamedReplyAndRecordsTranscript() async throws {
        let session = BrainSession(launch: try fakeLaunch())
        let stream = try await session.start()
        var iterator = stream.makeAsyncIterator()

        try await session.send("hi")
        let reply = await nextTurn(&iterator)
        #expect(reply == "echo: hi")

        let messages = await session.messages()
        #expect(messages.count == 2)
        #expect(messages[0].role == .user)
        #expect(messages[0].text == "hi")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].text == "echo: hi")

        await session.stop()
    }

    @Test func persistsAcrossMultipleTurns() async throws {
        let session = BrainSession(launch: try fakeLaunch())
        let stream = try await session.start()
        var iterator = stream.makeAsyncIterator()

        try await session.send("one")
        #expect(await nextTurn(&iterator) == "echo: one")

        try await session.send("two")
        #expect(await nextTurn(&iterator) == "echo: two")

        let messages = await session.messages()
        #expect(messages.count == 4)
        #expect(messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(messages[3].text == "echo: two")

        await session.stop()
    }

    @Test func statusGoesThinkingThenIdleAroundATurn() async throws {
        let session = BrainSession(launch: try fakeLaunch())
        let stream = try await session.start()
        var iterator = stream.makeAsyncIterator()

        try await session.send("ping")
        var sawThinking = false
        var sawIdleAfterTurn = false
        loop: while let event = await iterator.next() {
            switch event {
            case .status(.thinking):
                sawThinking = true
            case .turnCompleted:
                // The .status(.idle) is emitted right after .turnCompleted.
                if case .status(.idle)? = await iterator.next() {
                    sawIdleAfterTurn = true
                }
                break loop
            default:
                break
            }
        }
        #expect(sawThinking)
        #expect(sawIdleAfterTurn)

        await session.stop()
    }

    /// Regression for the Brain-not-responding bug: real Claude Code emits
    /// per-token text under a `stream_event` envelope (not bare
    /// `content_block_delta`) and a terminal `result` (not `message_stop`). The
    /// fake now emits those exact shapes plus `system` hook/init noise; the
    /// parser must still surface the assistant text and complete the turn.
    @Test func parsesRealStreamJsonEnvelopeShapes() async throws {
        let session = BrainSession(launch: try fakeLaunch())
        let stream = try await session.start()
        var iterator = stream.makeAsyncIterator()

        try await session.send("hello")
        let reply = await nextTurn(&iterator)
        #expect(reply == "echo: hello")

        let messages = await session.messages()
        #expect(messages.count == 2)
        #expect(messages[1].role == .assistant)
        // Exactly once — the full `assistant` message must NOT double-append on
        // top of the streamed partial deltas.
        #expect(messages[1].text == "echo: hello")

        await session.stop()
    }

    /// When no partial `stream_event` deltas are streamed, the assistant text
    /// must still be recovered from the full `assistant` message.
    @Test func recoversAssistantTextFromFullMessageWithoutPartials() async throws {
        let session = BrainSession(launch: try fakeLaunch(resource: "fake-claude-no-partials"))
        let stream = try await session.start()
        var iterator = stream.makeAsyncIterator()

        try await session.send("world")
        let reply = await nextTurn(&iterator)
        #expect(reply == "echo: world")

        let messages = await session.messages()
        #expect(messages.count == 2)
        #expect(messages[1].text == "echo: world")

        await session.stop()
    }

    /// An errored terminal `result` must complete the turn in `.failed` (not
    /// silently `.idle`) so the UI surfaces the failure.
    @Test func errorResultEndsTurnInFailedStatus() async throws {
        let session = BrainSession(launch: try fakeLaunch(resource: "fake-claude-error"))
        let stream = try await session.start()
        var iterator = stream.makeAsyncIterator()

        try await session.send("boom")
        var sawTurnCompleted = false
        var failure: String?
        loop: while let event = await iterator.next() {
            switch event {
            case .turnCompleted:
                sawTurnCompleted = true
            case .status(.failed(let detail)):
                failure = detail
                break loop
            case .status(.idle):
                // The startup `.idle` precedes the turn; only an `.idle` AFTER
                // the turn completed would be the silent-recovery bug.
                if sawTurnCompleted {
                    Issue.record("error turn must not return to .idle")
                    break loop
                }
            default:
                break
            }
        }
        #expect(sawTurnCompleted)
        #expect(failure == "overloaded")

        await session.stop()
    }

    @Test func stopTerminatesAndFinishesStream() async throws {
        let session = BrainSession(launch: try fakeLaunch())
        let stream = try await session.start()

        await session.stop()

        // Draining the stream must complete (it finishes after `.exited`) rather
        // than hang — proving teardown closes the persistent process cleanly.
        var sawExit = false
        for await event in stream {
            if case .exited = event { sawExit = true }
        }
        #expect(sawExit)
    }
}
