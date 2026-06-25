import Foundation

/// Shared classification of whether an orchestrator worker's `.failed` exit
/// describes a process that was **killed by a termination signal**
/// (SIGTERM/SIGKILL/SIGINT…) rather than one that chose to exit non-zero.
///
/// ## Why this exists
/// Both loop drivers — the generic brain loop and the ci-fix "until green" loop —
/// spawn one agent worker per iteration through the ``RegattaOrchestrator``. An
/// explicit user cancel routes through ``RegattaOrchestrator/cancelWorker(_:)``
/// and marks the worker `.cancelled`, which both loops already treat as a final
/// stop. But a worker whose process is killed by a signal *outside* that path
/// (the runaway the user dogfooded: "a SIGKILLed worker, exit 9, triggered a
/// respawn") surfaces as `.failed("agent exited with code 9")`. Treating that as
/// an ordinary failed iteration let the loop advance and respawn. A signal kill
/// is a cancellation, not a self-inflicted failure, so it must stop the loop.
///
/// The orchestrator formats a worker's terminal failure as
/// `"agent exited with code <N>"`. The pane bridge reports a signal kill as the
/// signal number (Foundation's `Process.terminationStatus` is the signal for an
/// uncaught signal, e.g. 9/15) or, when it force-finishes a terminated pane, as
/// `SIGTERM` (15). Shells and some toolchains report the same kill as `128 +
/// signal` (137 = SIGKILL, 143 = SIGTERM) or a negative code. This helper treats
/// all of those as a termination-signal kill.
///
/// Lives in `RegattaCore` so it can be exercised headlessly under `swift test`
/// (the app target's spawner and loop-engine provider both use it).
public enum RegattaCancellationExit {

    /// The signal numbers a cancellation actually sends that we treat as a kill:
    /// SIGKILL (9) and SIGTERM (15). Deliberately limited to these two — lower
    /// signal numbers like SIGHUP(1)/SIGINT(2)/SIGQUIT(3) collide with ordinary
    /// non-zero exit codes (exit 1 and 2 are everyday failures, not kills), so
    /// treating a bare 1/2/3 as a kill would misclassify a real failed iteration
    /// as a cancel. 9/15 (and their 128+ shell forms 137/143) are unambiguous.
    private static let killSignals: Set<Int> = [9, 15]

    /// Whether `reason` (a worker `.failed` reason string) describes a process
    /// killed by a termination signal, which a loop must treat as a cancel-stop.
    public static func isTerminationSignalFailure(_ reason: String) -> Bool {
        guard let code = exitCode(from: reason) else { return false }
        return isTerminationSignal(code)
    }

    /// Whether a raw process exit/termination code denotes a kill signal.
    public static func isTerminationSignal(_ code: Int) -> Bool {
        // A negative code is the conventional "killed by signal -code".
        if code < 0 { return isTerminationSignal(-code) }
        // Bare signal number (Foundation reports the signal directly).
        if killSignals.contains(code) { return true }
        // Shell convention: 128 + signal.
        if code > 128, killSignals.contains(code - 128) { return true }
        return false
    }

    /// Extracts the trailing integer exit code from an
    /// `"agent exited with code <N>"`-style reason, or `nil` if there is none
    /// (e.g. the "unknown" placeholder for a missing code).
    private static func exitCode(from reason: String) -> Int? {
        let trailing = reason.reversed().prefix { $0.isNumber || $0 == "-" }
        let token = String(trailing.reversed())
        return Int(token)
    }
}
