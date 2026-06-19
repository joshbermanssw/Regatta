import Foundation

/// A persistent brain agent process with streaming chat I/O.
///
/// Spawns a long-lived process (Claude Code in production), writes user messages
/// to its stdin as newline-delimited stream-JSON, and parses its stdout stream
/// incrementally — emitting ``BrainEvent`` values (text deltas, turn completion,
/// status, exit) over an `AsyncStream`. The process stays alive across turns
/// until ``stop()``.
///
/// ## Streaming + concurrency safety
/// Stdout is consumed via `FileHandle.readabilityHandler` (a non-blocking
/// callback on a background queue) — never a blocking read on a Swift task,
/// which would starve the cooperative thread pool and wedge the actor. Pipe
/// file descriptors are set close-on-exec so a concurrently-spawned sibling
/// can't inherit a pipe write-end and stall the reader (the deadlock class that
/// bit RegattaCore on CI).
///
/// ## Test pattern (important)
/// The process is *persistent* — its stdout never reaches EOF until ``stop()``.
/// Consumers read events until `.turnCompleted` (not until the stream ends),
/// then call ``stop()``. The session also finishes the stream from the process
/// `terminationHandler`, so a consumer that drains to completion after `stop()`
/// terminates cleanly rather than hanging.
public actor BrainSession {
    private let launch: BrainLaunch

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readHandle: FileHandle?
    private var continuation: AsyncStream<BrainEvent>.Continuation?

    private var readBuffer = Data()
    private var transcript: [BrainMessage] = []
    private var assistantInProgress = false
    private var userCounter = 0
    private var assistantCounter = 0
    private var finished = false

    public init(launch: BrainLaunch) {
        self.launch = launch
    }

    /// Spawns the process and returns the event stream. Call once.
    public func start() throws -> AsyncStream<BrainEvent> {
        let proc = Process()
        proc.executableURL = launch.executableURL
        proc.arguments = launch.arguments
        if !launch.environment.isEmpty {
            proc.environment = launch.environment
        }
        if let workingDirectory = launch.workingDirectory {
            proc.currentDirectoryURL = workingDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        // Close-on-exec on every pipe end: posix_spawn still dup2's these into
        // the intended child, but other concurrently-spawned children can't
        // inherit them — which would otherwise keep a write-end open and hang
        // the reader (the RegattaCore CI deadlock).
        for handle in [
            stdinPipe.fileHandleForReading, stdinPipe.fileHandleForWriting,
            stdoutPipe.fileHandleForReading, stdoutPipe.fileHandleForWriting,
            stderrPipe.fileHandleForReading, stderrPipe.fileHandleForWriting,
        ] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        let (stream, continuation) = AsyncStream<BrainEvent>.makeStream()
        self.continuation = continuation
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.process = proc

        proc.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { await self?.finish(code: code) }
        }

        do {
            try proc.run()
        } catch {
            continuation.yield(.status(.failed("\(error)")))
            continuation.finish()
            throw error
        }

        continuation.yield(.status(.idle))

        // Non-blocking, callback-driven stdout consumption.
        let readHandle = stdoutPipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                Task { await self?.handleStreamEnd() }
            } else {
                Task { await self?.ingest(data) }
            }
        }
        self.readHandle = readHandle

        return stream
    }

    /// Sends a user message to the brain (newline-terminated stream-JSON).
    public func send(_ text: String) throws {
        guard let stdinHandle else { return }
        userCounter += 1
        transcript.append(BrainMessage(id: "u\(userCounter)", role: .user, text: text))
        continuation?.yield(.status(.thinking))

        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [])
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    /// The accumulated transcript (user messages + assembled assistant turns).
    public func messages() -> [BrainMessage] {
        transcript
    }

    /// Terminates the process and finishes the stream. Idempotent.
    public func stop() {
        readHandle?.readabilityHandler = nil
        guard let process, process.isRunning else {
            finish(code: process?.terminationStatus ?? 0)
            return
        }
        process.terminate()
        let pid = process.processIdentifier
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let self, await self.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Private (actor-isolated stream handling)

    /// Appends a raw stdout chunk and processes any complete newline-delimited
    /// lines. Runs on the actor; the readability callback hops here in order.
    private func ingest(_ data: Data) {
        readBuffer.append(data)
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer.subdata(in: readBuffer.startIndex..<newlineIndex)
            readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
            consume(line: lineData)
        }
    }

    private func consume(line data: Data) {
        guard
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        switch type {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any],
               let text = delta["text"] as? String,
               !text.isEmpty {
                appendAssistantDelta(text)
                continuation?.yield(.assistantDelta(text))
            }
        case "message_stop", "result", "done":
            assistantInProgress = false
            continuation?.yield(.turnCompleted)
            continuation?.yield(.status(.idle))
        default:
            break
        }
    }

    private func appendAssistantDelta(_ text: String) {
        if !assistantInProgress {
            assistantCounter += 1
            transcript.append(BrainMessage(id: "a\(assistantCounter)", role: .assistant, text: text))
            assistantInProgress = true
        } else if let last = transcript.indices.last, transcript[last].role == .assistant {
            transcript[last].text += text
        }
    }

    private func handleStreamEnd() {
        if let process, !process.isRunning {
            finish(code: process.terminationStatus)
        }
    }

    private func finish(code: Int32) {
        guard !finished else { return }
        finished = true
        continuation?.yield(.status(.exited(code)))
        continuation?.yield(.exited(code: code))
        continuation?.finish()
        continuation = nil
    }
}
