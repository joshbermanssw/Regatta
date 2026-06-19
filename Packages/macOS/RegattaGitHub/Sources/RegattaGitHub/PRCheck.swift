/// The status of an individual CI check on a pull request.
///
/// Maps to entries in the `statusCheckRollup` array returned by
/// `gh pr view --json statusCheckRollup`.
public struct PRCheck: Sendable, Equatable, Hashable {
    /// The display name of the check (e.g. `"build"`, `"test (macos-14)"`).
    public let name: String
    /// The current status of the check runner
    /// (e.g. `"QUEUED"`, `"IN_PROGRESS"`, `"COMPLETED"`).
    public let status: String
    /// The conclusion once the check has completed
    /// (e.g. `"SUCCESS"`, `"FAILURE"`, `"CANCELLED"`, `"SKIPPED"`), or `nil`
    /// while still in progress.
    public let conclusion: String?
    /// The URL to the check-run detail page on GitHub, if available.
    public let detailsURL: String?

    /// Creates a `PRCheck`.
    public init(name: String, status: String, conclusion: String?, detailsURL: String?) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.detailsURL = detailsURL
    }
}

/// A rolled-up view of all CI checks for a pull request.
public struct PRCheckSummary: Sendable, Equatable {
    /// Every individual check associated with the pull request.
    public let checks: [PRCheck]

    /// Creates a `PRCheckSummary`.
    public init(checks: [PRCheck]) {
        self.checks = checks
    }

    /// Whether every check has completed with a success conclusion.
    public var allSucceeded: Bool {
        !checks.isEmpty && checks.allSatisfy {
            $0.status == "COMPLETED" && $0.conclusion == "SUCCESS"
        }
    }

    /// Whether any check has completed with a failure conclusion.
    public var anyFailed: Bool {
        checks.contains {
            $0.status == "COMPLETED" && ($0.conclusion == "FAILURE" || $0.conclusion == "ACTION_REQUIRED" || $0.conclusion == "TIMED_OUT")
        }
    }

    /// Whether any check is still queued or in progress.
    public var anyPending: Bool {
        checks.contains { $0.status != "COMPLETED" }
    }
}
