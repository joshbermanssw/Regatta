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
    /// Set once ``stop()`` is invoked, so the resulting termination is reported
    /// as a clean exit (code 0) rather than a SIGTERM signal number that the UI
    /// would mistake for an unexpected crash.
    private var stopping = false

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
        stopping = true
        readHandle?.readabilityHandler = nil
        guard let process, process.isRunning else {
            finish(code: process?.terminationStatus ?? 0)
            return
        }
        process.terminate()
        let capturedProcess = process
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // Guard on the same Process object to avoid escalating against a
            // recycled pid if a new process started after this one exited.
            if capturedProcess.isRunning {
                _ = self  // keep actor alive for the duration
                capturedProcess.terminate()
                kill(capturedProcess.processIdentifier, SIGKILL)
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

    /// Parses one newline-delimited stream-JSON line emitted by Claude Code.
    ///
    /// Handles the *real* wire format produced by
    /// `claude -p --output-format stream-json --include-partial-messages`:
    ///
    /// - `{"type":"stream_event","event":{"type":"content_block_delta",
    ///   "delta":{"type":"text_delta","text":"…"}}}` — incremental partial text.
    /// - `{"type":"assistant","message":{"content":[{"type":"text","text":"…"}]}}`
    ///   — the full assistant message (the fallback when partial deltas weren't
    ///   streamed, e.g. partial messages disabled or a tool-free reply).
    /// - `{"type":"result","subtype":"success","result":"…","is_error":false}`
    ///   — turn completion; `is_error`/non-`success` surfaces a failure.
    /// - `{"type":"system",…}` — init, status, hook lifecycle, api_retry noise:
    ///   ignored (except `api_error`-style fatal subtypes are not emitted here).
    ///
    /// Also still accepts the bare top-level `content_block_delta` /
    /// `message_stop` shapes for forward/backward compatibility.
    private func consume(line data: Data) {
        guard
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        switch type {
        case "stream_event":
            // Partial-message envelope. The real per-token deltas live nested
            // under `event` — this is what `--include-partial-messages` emits.
            if let event = object["event"] as? [String: Any] {
                consumeStreamEvent(event)
            }
        case "assistant":
            // Full assistant message. Treat its text as the authoritative turn
            // text only when no streamed deltas were already accumulated, so we
            // don't double-append when both partial deltas and the final
            // message arrive (the normal `--include-partial-messages` case).
            if !assistantInProgress {
                let text = assistantText(in: object["message"] as? [String: Any])
                if !text.isEmpty {
                    appendAssistantDelta(text)
                    continuation?.yield(.assistantDelta(text))
                }
            }
        case "content_block_delta":
            // Bare (non-enveloped) delta — tolerated for compatibility.
            if let text = textDelta(in: object) {
                appendAssistantDelta(text)
                continuation?.yield(.assistantDelta(text))
            }
        case "result":
            handleTurnEnd(resultObject: object)
        case "message_stop", "done":
            handleTurnEnd(resultObject: nil)
        case "system", "rate_limit_event", "user", "stream_request_start":
            // Lifecycle / hook / retry / echo noise — intentionally ignored so a
            // heavy global agent config can't break parsing.
            break
        default:
            break
        }
    }

    /// Handles the nested `event` object of a `stream_event` envelope.
    private func consumeStreamEvent(_ event: [String: Any]) {
        guard let eventType = event["type"] as? String else { return }
        switch eventType {
        case "content_block_delta":
            if let text = textDelta(in: event) {
                appendAssistantDelta(text)
                continuation?.yield(.assistantDelta(text))
            }
        default:
            // message_start / content_block_start / message_delta /
            // content_block_stop / message_stop — framing only. The turn is
            // completed by the top-level `result` event, not here, so partial
            // and non-partial streams complete via the same path.
            break
        }
    }

    /// Extracts the text from a `content_block_delta`-shaped object, accepting
    /// both `{"delta":{"text":"…"}}` and `{"delta":{"type":"text_delta",
    /// "text":"…"}}`.
    private func textDelta(in object: [String: Any]) -> String? {
        guard
            let delta = object["delta"] as? [String: Any],
            let text = delta["text"] as? String,
            !text.isEmpty
        else { return nil }
        return text
    }

    /// Concatenates the `text` of every text content block in an assistant
    /// `message` object.
    private func assistantText(in message: [String: Any]?) -> String {
        guard let blocks = message?["content"] as? [[String: Any]] else { return "" }
        var text = ""
        for block in blocks where (block["type"] as? String) == "text" {
            if let blockText = block["text"] as? String { text += blockText }
        }
        return text
    }

    /// Completes the current assistant turn. When a `result` event carries an
    /// error, surfaces `.failed` before completing so the UI never silently
    /// shows nothing.
    private func handleTurnEnd(resultObject: [String: Any]?) {
        assistantInProgress = false
        if let result = resultObject, isErrorResult(result) {
            let detail = (result["result"] as? String)
                ?? (result["error"] as? String)
                ?? (result["subtype"] as? String)
                ?? "error"
            // An errored turn ends in `.failed`, not `.idle`, so the chrome keeps
            // showing the failure rather than silently returning to ready.
            continuation?.yield(.turnCompleted)
            continuation?.yield(.status(.failed(detail)))
            return
        }
        continuation?.yield(.turnCompleted)
        continuation?.yield(.status(.idle))
    }

    /// Whether a `result` event represents a failed turn.
    private func isErrorResult(_ result: [String: Any]) -> Bool {
        if let isError = result["is_error"] as? Bool, isError { return true }
        if let subtype = result["subtype"] as? String, subtype != "success" { return true }
        return false
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
        // A user-initiated ``stop()`` terminates via SIGTERM, whose
        // `terminationStatus` is the signal number — report it as a clean exit so
        // the UI doesn't surface a spurious "stopped unexpectedly" error.
        let reportedCode = stopping ? 0 : code
        continuation?.yield(.status(.exited(reportedCode)))
        continuation?.yield(.exited(code: reportedCode))
        continuation?.finish()
        continuation = nil
    }
}
