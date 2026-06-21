/// Records the per-iteration judging side-channel — LLM verdicts and dry-diff
/// results — so they survive alongside the loop's iteration history.
///
/// The engine's ``RegattaIterationRecord`` is closed to extension (issue #21
/// must not modify the #19 engine), so the dry and LLM-judged conditions write
/// their prompts and verdicts here instead. A view model reads the journal back
/// to render "iteration N: judge said goal met because …" next to the engine's
/// timeline.
///
/// All mutable state lives in this actor; the dry/LLM workers (which run on the
/// engine's actor) `await` into it, so there are no locks.
public actor RegattaLoopJournal {
    /// Why a dry iteration did or did not produce new changes.
    public struct DryRecord: Equatable, Sendable {
        /// The iteration this record describes.
        public let iterationIndex: Int
        /// Whether the iteration produced new git changes in the worktree.
        public let hadNewChanges: Bool
        /// A short, human-readable note for the history (e.g. the diff summary).
        public let detail: String

        /// Creates a dry record.
        public init(iterationIndex: Int, hadNewChanges: Bool, detail: String) {
            self.iterationIndex = iterationIndex
            self.hadNewChanges = hadNewChanges
            self.detail = detail
        }
    }

    private var verdicts: [RegattaJudgeVerdict] = []
    private var dryRecords: [DryRecord] = []

    /// Creates an empty journal.
    public init() {}

    // MARK: - Writes (called by the dry / LLM-judged workers)

    /// Appends a judge verdict for the iteration it assessed.
    public func record(_ verdict: RegattaJudgeVerdict) {
        verdicts.append(verdict)
    }

    /// Appends a dry-diff record for the iteration it describes.
    public func record(_ dryRecord: DryRecord) {
        dryRecords.append(dryRecord)
    }

    // MARK: - Reads (queryable for the UI)

    /// All recorded LLM verdicts, in the order they were assessed.
    public func allVerdicts() -> [RegattaJudgeVerdict] {
        verdicts
    }

    /// The verdict for a specific iteration, or `nil` if none was recorded.
    public func verdict(forIteration index: Int) -> RegattaJudgeVerdict? {
        verdicts.first { $0.iterationIndex == index }
    }

    /// All recorded dry-diff records, in the order they were observed.
    public func allDryRecords() -> [DryRecord] {
        dryRecords
    }

    /// The dry record for a specific iteration, or `nil` if none was recorded.
    public func dryRecord(forIteration index: Int) -> DryRecord? {
        dryRecords.first { $0.iterationIndex == index }
    }
}
