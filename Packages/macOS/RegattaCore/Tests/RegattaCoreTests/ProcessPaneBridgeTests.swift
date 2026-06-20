import Foundation
import Testing
@testable import RegattaCore

/// Behavior tests for ``ProcessPaneBridge`` — the default ``PaneBridge`` implementation
/// that runs an agent process and exposes its output stream for downstream condition checks
/// (issue #14).
///
/// The bridge is driven through `fake-agent.sh` (issue #10) so every test runs headlessly on
/// CI with no real Ghostty pane. Each test resolves the script via `Bundle.module` and writes
/// a per-run fixture, mirroring `FakeAgent`'s spawn shape.
@Suite struct ProcessPaneBridgeTests {

    // MARK: - Fixtures

    /// Resolves `fake-agent.sh` from the test bundle.
    private func scriptPath() throws -> String {
        guard let url = Bundle.module.url(forResource: "fake-agent", withExtension: "sh") else {
            Issue.record("fake-agent.sh missing from Bundle.module")
            throw FakeAgentError.scriptNotFound("Bundle.module")
        }
        return url.path
    }

    /// Writes a fixture file from a ``FakeAgentScript`` and returns its path.
    private func writeFixture(_ script: FakeAgentScript) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-bridge-fixture-\(UUID().uuidString).txt").path
        try script.fixtureText().write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Builds a ``PaneSpec`` that runs `fake-agent.sh <fixture>` in `cwd`.
    private func spec(
        for script: FakeAgentScript,
        cwd: URL
    ) throws -> PaneSpec {
        let fixture = try writeFixture(script)
        return PaneSpec(
            workingDirectory: cwd,
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [try scriptPath(), fixture],
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
                "TMPDIR": NSTemporaryDirectory(),
            ]
        )
    }

    /// Collects all output events from a handle's stream into an array.
    private func collect(_ handle: PaneHandle) async -> [PaneOutputEvent] {
        var events: [PaneOutputEvent] = []
        for await event in handle.output {
            events.append(event)
        }
        return events
    }

    // MARK: - spawn + observe stdout

    /// Spawning an agent yields its stdout on the observable stream and a terminated event with
    /// the exit code.
    @Test func spawnEmitsStdoutAndExit() async throws {
        let bridge = ProcessPaneBridge()
        let cwd = FileManager.default.temporaryDirectory
        let handle = try await bridge.spawn(
            try spec(for: FakeAgentScript(steps: [.out("hello"), .out("world")], exitCode: 0), cwd: cwd)
        )

        let events = await collect(handle)

        let stdout = events.compactMap { if case .stdout(let s) = $0 { return s } else { return nil } }.joined()
        #expect(stdout.contains("hello"), "stdout should contain hello; got \(stdout)")
        #expect(stdout.contains("world"), "stdout should contain world; got \(stdout)")

        let terminations = events.compactMap { if case .terminated(let code) = $0 { return code } else { return nil } }
        #expect(terminations == [0], "exactly one terminated(0) event expected; got \(terminations)")
    }

    // MARK: - observe stderr + nonzero exit

    /// Stderr output is surfaced distinctly from stdout and a non-zero exit code is reported.
    @Test func spawnEmitsStderrAndNonZeroExit() async throws {
        let bridge = ProcessPaneBridge()
        let cwd = FileManager.default.temporaryDirectory
        let handle = try await bridge.spawn(
            try spec(for: FakeAgentScript(steps: [.err("boom")], exitCode: 7), cwd: cwd)
        )

        let events = await collect(handle)

        let stderr = events.compactMap { if case .stderr(let s) = $0 { return s } else { return nil } }.joined()
        #expect(stderr.contains("boom"), "stderr should contain boom; got \(stderr)")

        let terminations = events.compactMap { if case .terminated(let code) = $0 { return code } else { return nil } }
        #expect(terminations == [7], "expected terminated(7); got \(terminations)")
    }

    // MARK: - cwd is honored

    /// The agent process runs in the working directory named by the spec.
    @Test func spawnRunsInWorkingDirectory() async throws {
        let bridge = ProcessPaneBridge()
        // Make a unique temp dir and resolve symlinks so /var vs /private/var matches.
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let resolved = cwd.resolvingSymlinksInPath().path

        // Spawn /bin/pwd directly so the test asserts the bridge sets currentDirectoryURL.
        let handle = try await bridge.spawn(
            PaneSpec(
                workingDirectory: cwd,
                executableURL: URL(fileURLWithPath: "/bin/pwd"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"]
            )
        )

        let events = await collect(handle)
        let stdout = events.compactMap { if case .stdout(let s) = $0 { return s } else { return nil } }.joined()
        #expect(
            stdout.contains(resolved),
            "pwd output should contain the resolved cwd \(resolved); got \(stdout)"
        )
    }

    // MARK: - terminate kills a long-running process

    /// Terminating a running agent stops the process promptly and emits a terminated event;
    /// the stream finishes.
    @Test func terminateStopsRunningAgent() async throws {
        let bridge = ProcessPaneBridge()
        let cwd = FileManager.default.temporaryDirectory
        // A long sleep so the process is still alive when we terminate it.
        let handle = try await bridge.spawn(
            try spec(for: FakeAgentScript(steps: [.out("started"), .sleepMs(60_000)], exitCode: 0), cwd: cwd)
        )

        // Collect on a child task; signal when the start marker appears.
        let started = SignalBox()
        let collector = Task { () -> [PaneOutputEvent] in
            var events: [PaneOutputEvent] = []
            for await event in handle.output {
                events.append(event)
                if case .stdout(let s) = event, s.contains("started") { await started.signal() }
            }
            return events
        }

        // Wait for the real start signal before terminating (no sleep-poll).
        await started.wait()

        try await bridge.terminate(handle.id)
        let events = await collector.value

        let terminations = events.compactMap { if case .terminated = $0 { return true } else { return nil } }
        #expect(!terminations.isEmpty, "a terminated event must be emitted after terminate()")

        let running = await bridge.isRunning(handle.id)
        #expect(running == false, "handle should not be running after terminate()")
    }

    // MARK: - terminate is idempotent / unknown handle

    /// Terminating an unknown or already-finished handle throws a typed error rather than crashing.
    @Test func terminateUnknownHandleThrows() async throws {
        let bridge = ProcessPaneBridge()
        await #expect(throws: PaneBridgeError.self) {
            try await bridge.terminate(PaneHandle.ID())
        }
    }
}

/// A one-shot async signal used by tests to wait for a stream marker without polling.
private actor SignalBox {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            signaled = true
        }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { continuation in
            if signaled {
                continuation.resume()
            } else {
                waiter = continuation
            }
        }
    }
}
