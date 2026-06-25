import Testing
@testable import RegattaCore

/// Headless coverage for the signal-kill classification both loop drivers use to
/// treat a SIGKILL/SIGTERM worker exit as a cancel-stop (not a retry-able failure)
/// — the dogfooded runaway where a SIGKILLed worker (exit 9) triggered a respawn.
///
/// Ports `OrchestratorWorkerSpawnerTests.killSignalExitClassified` /
/// `ordinaryExitNotClassifiedAsKill` to `swift test` (the app-host suite that
/// originally held them could not run in CI).
@Suite("RegattaCancellationExit signal-kill classification (headless)")
struct RegattaCancellationExitTests {

    @Test("a SIGKILL/SIGTERM worker exit is classified as a termination-signal kill")
    func killSignalExitClassified() {
        #expect(RegattaCancellationExit.isTerminationSignalFailure("agent exited with code 9"))   // SIGKILL
        #expect(RegattaCancellationExit.isTerminationSignalFailure("agent exited with code 15"))  // SIGTERM
        #expect(RegattaCancellationExit.isTerminationSignalFailure("agent exited with code 137")) // 128+9
        #expect(RegattaCancellationExit.isTerminationSignalFailure("agent exited with code 143")) // 128+15
        #expect(RegattaCancellationExit.isTerminationSignalFailure("agent exited with code -9"))  // killed by 9
    }

    @Test("an ordinary non-zero exit is NOT a termination-signal kill")
    func ordinaryExitNotClassifiedAsKill() {
        #expect(!RegattaCancellationExit.isTerminationSignalFailure("agent exited with code 1"))
        #expect(!RegattaCancellationExit.isTerminationSignalFailure("agent exited with code 127"))
        #expect(!RegattaCancellationExit.isTerminationSignalFailure("agent exited with code unknown"))
    }
}
