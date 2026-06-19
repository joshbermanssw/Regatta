public import Foundation

/// Records the origin of a memory fact: who wrote it, when, and from what context.
public struct MemoryProvenance: Codable, Sendable, Equatable {
    /// The identifier of the worker agent that recorded the fact (e.g. a worktree
    /// name or agent session ID). `nil` if the fact was recorded by a human or a
    /// system with no worker context.
    public var workerID: String?

    /// The pull-request identifier associated with the work that produced this
    /// fact (e.g. `"manaflow-ai/cmux#1234"`). `nil` when the fact was not derived
    /// from a specific PR.
    public var sourcePR: String?

    /// A human-readable description of the context that produced this fact (e.g.
    /// "loop iteration 3 of feat/memory-store", or "manual entry").
    public var sourceDescription: String

    /// The timestamp at which this provenance was captured (i.e. when the fact
    /// was originally created or updated).
    public var recordedAt: Date

    public init(
        workerID: String? = nil,
        sourcePR: String? = nil,
        sourceDescription: String,
        recordedAt: Date
    ) {
        self.workerID = workerID
        self.sourcePR = sourcePR
        self.sourceDescription = sourceDescription
        self.recordedAt = recordedAt
    }
}
