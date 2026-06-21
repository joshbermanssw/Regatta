public import RegattaFleet
public import RegattaGitHub

/// One resumed PR shepherd: its watched PR, its restored autonomy mode, the
/// last-known seed state to show until the first fresh poll, and the live,
/// already-polling ``RegattaFleet/ShepherdWatcher``.
public struct ResumedShepherd: Sendable {
    /// The pull request this shepherd watches.
    public let pullRequest: PullRequestRef

    /// The autonomy mode restored for this PR.
    public let autonomyMode: AutonomyMode

    /// The last-known persisted snapshot, shown until the first fresh poll lands.
    public let seedState: ShepherdState

    /// The live watcher, already started (polling).
    public let watcher: ShepherdWatcher

    /// Creates a resumed-shepherd record.
    public init(
        pullRequest: PullRequestRef,
        autonomyMode: AutonomyMode,
        seedState: ShepherdState,
        watcher: ShepherdWatcher
    ) {
        self.pullRequest = pullRequest
        self.autonomyMode = autonomyMode
        self.seedState = seedState
        self.watcher = watcher
    }
}

/// Resumes PR shepherds from persisted state on launch (issue #34 acceptance
/// criterion "PR shepherds resume polling automatically").
///
/// PR shepherds are event-driven, not process-backed: unlike a worker's agent
/// process, a shepherd is just a poller. So restore is straightforward — for each
/// persisted ``RegattaFleet/ShepherdState`` we build a fresh
/// ``RegattaFleet/ShepherdWatcher`` against the injected poller and **start it**,
/// which immediately begins the recurring poll loop. The persisted snapshot is
/// returned as the seed the Fleet shows until the first fresh poll completes.
///
/// The poller and poll interval are injected so tests resume shepherds against a
/// deterministic fake poller and assert polling actually resumed (by driving a
/// poll cycle), with no real `gh` invocation or network access.
public struct RegattaShepherdResumer: Sendable {

    private let poller: any PullRequestPolling
    private let pollInterval: Duration

    /// Creates a resumer.
    ///
    /// - Parameters:
    ///   - poller: The polling seam each resumed watcher uses. Defaults to the
    ///     production ``RegattaGitHub/GitHubPoller``.
    ///   - pollInterval: How long each resumed watcher waits between polls.
    ///     Defaults to 30 seconds, matching ``RegattaFleet/ShepherdWatcher``.
    public init(
        poller: any PullRequestPolling = GitHubPoller(),
        pollInterval: Duration = .seconds(30)
    ) {
        self.poller = poller
        self.pollInterval = pollInterval
    }

    /// Resumes every shepherd in a snapshot, starting each watcher's poll loop.
    ///
    /// The autonomy mode for each PR is taken from
    /// ``RegattaStateSnapshot/autonomyModes`` when present, otherwise from the
    /// shepherd's own persisted ``RegattaFleet/ShepherdState/autonomyMode``.
    ///
    /// - Parameter snapshot: The loaded state snapshot.
    /// - Returns: One ``ResumedShepherd`` per persisted shepherd, each with a
    ///   live, already-started watcher.
    public func resume(from snapshot: RegattaStateSnapshot) async -> [ResumedShepherd] {
        var resumed: [ResumedShepherd] = []
        for seed in snapshot.shepherds {
            let mode = snapshot.autonomyModes[seed.pullRequest.id] ?? seed.autonomyMode
            let watcher = ShepherdWatcher(
                pullRequest: seed.pullRequest,
                poller: poller,
                pollInterval: pollInterval
            )
            await watcher.start()
            resumed.append(
                ResumedShepherd(
                    pullRequest: seed.pullRequest,
                    autonomyMode: mode,
                    seedState: seed,
                    watcher: watcher
                )
            )
        }
        return resumed
    }
}
