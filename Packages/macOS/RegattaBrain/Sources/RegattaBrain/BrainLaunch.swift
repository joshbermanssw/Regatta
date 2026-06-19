public import Foundation

/// How to launch the brain's underlying agent process.
///
/// Injected into ``BrainSession`` so production can launch a real Claude Code
/// process (stream-json mode) while tests inject a fake stream-json emitter —
/// no real CLI or network needed.
public struct BrainLaunch: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}
