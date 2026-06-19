# cmux Architecture Map for Regatta

## Executive Summary

cmux is a native macOS (Swift/AppKit + SwiftUI) terminal multiplexer that wraps the
Ghostty terminal library and layers a rich pane/workspace/sidebar UI on top of it.
Every visible pane is a `Panel` — either a `TerminalPanel` (backed by a
`ghostty_surface_t`) or an `AgentSessionPanel` (backed by a WKWebView shell that drives
a native child process over stdio). Panels are owned by `Workspace` instances (one per
tab) and arranged spatially by the **Bonsplit** split-tree library. `TabManager` (one
per window) holds the ordered list of workspaces and orchestrates focus.

The most important seam for Regatta is the **Pane Bridge**
(`Sources/Panels/AgentSessionProcessStore.swift`), which spawns/monitors/kills agent
processes (codex, claude, opencode) and streams their output to a WKWebView renderer
via a `[String: Any]` event dictionary. This seam is entirely in-process, requires no
socket or IPC, and is the correct injection point for Regatta's orchestration layer.

---

## Seam 1: Window / Pane / Split Layout

### Key Files and Types

| File | Type / Role |
|------|------------|
| `Sources/TerminalWindowPortal.swift` | `WindowTerminalHostView` (NSView) — root hit-test view that covers the entire window content area; routes cursor rects for Bonsplit dividers and sidebar edge |
| `Sources/ContentView.swift` | SwiftUI entry point for each window; mounts `WorkspaceContentView`, overlay containers, command palette, tmux overlay |
| `Sources/WorkspaceContentView.swift` | Per-workspace SwiftUI view; mounts `TmuxWorkspacePaneOverlayModel` and layout switcher |
| `Sources/Workspace.swift` (line 2076) | `final class Workspace: Identifiable, ObservableObject` — owns `bonsplitController`, `paneTree`, `surfaceList`, `splitLayout`; tab alias: `typealias Tab = Workspace` |
| `Sources/TabManager.swift` | `TabManager` — owns the ordered `[Workspace]` list per window, `tabsPublisher` (Combine), `pullRequestProbing`, focus routing |
| `Sources/AppDelegate.swift` | `AppDelegate` — application lifecycle; routes window creation, keyboard shortcut dispatch, session snapshot/restore |
| `Sources/Panels/Panel.swift` | `protocol Panel: AnyObject, Identifiable, ObservableObject` — the protocol shared by every pane type (`PanelType`: `.terminal`, `.browser`, `.agentSession`, `.markdown`, `.filePreview`, `.project`, `.extensionBrowser`) |
| `vendor/bonsplit` (submodule) | `BonsplitController` — binary-space-partition split tree; owns pane geometry; called as `workspace.bonsplitController.treeSnapshot()` for session persistence |

### Layout Model in `Workspace`

```swift
let bonsplitController: BonsplitController   // split geometry
let paneTree = PaneTreeModel<any Panel>()    // panel registry (UUID → Panel)
let surfaceList = WorkspaceSurfaceListModel() // ordered panel-id lists
private let splitLayout = SplitLayoutModel<DetachedSurfaceTransfer>()
var panels: [UUID: any Panel]               // forwarded from paneTree
```

### How Regatta Hooks In (persistent right-hand rail)

The right sidebar already exists as `RightSidebarPanelView`
(`Sources/RightSidebarPanelView.swift`), toggled by ⌘⌥B. It uses `RightSidebarMode`
(`.files`, `.find`, `.sessions`, `.feed`, `.dock`) and its width is managed by
`SidebarState` (`Sources/Sidebar/SidebarState.swift`).

To add a persistent Regatta orchestration rail:

1. Add a new `case regatta` to `RightSidebarMode` with an associated keyboard shortcut
   wired through `KeyboardShortcutSettings`.
2. Mount a SwiftUI view in `RightSidebarPanelView`'s mode switch under that case.
3. The rail can read `TabManager.tabs` (the workspace list) and observe any
   `Workspace.@Published` property (e.g. `agentPIDs`, `statusEntries`, `gitBranch`,
   `currentDirectory`) directly on `@MainActor`.

Alternatively, Regatta can add a new `Panel` subtype (add a case to `PanelType`) and
open it in a split via `Workspace.bonsplitController` — the existing split APIs are
used by `Workspace+PanelLifecycle.swift`.

---

## Seam 2: Terminal/Agent Pane Spawning (The Pane Bridge)

This is the critical integration seam. All files are in `Sources/` unless noted.

### Key Files and Types

| File | Type | Role |
|------|------|------|
| `Sources/AgentSessionProvider.swift` | `enum AgentSessionProviderID` | Identifies agent (`.codex`, `.claude`, `.opencode`); supplies `executableName`, `launchArguments`, `transportKind`, `shouldAutoStartSession` |
| `Sources/AgentSessionLaunchPlan.swift` | `struct AgentSessionLaunchPlan` | Value type: `provider`, `executableURL`, `arguments`, `environment`; `environment(overridingWorkingDirectory:)` injects `PWD` and opencode auth |
| `Sources/AgentExecutableResolver.swift` | `struct AgentExecutableResolver` | Walks `PATH` + well-known dirs to resolve an executable; avoids cmux shims and bundled wrappers; returns `AgentSessionLaunchPlan` |
| `Sources/AgentExecutableResolverError.swift` | `enum AgentExecutableResolverError` | `.missing(displayName:executableName:searchedDirectories:)` |
| `Sources/Panels/AgentSessionProcessStore.swift` | `@MainActor final class AgentSessionProcessStore` | **The spawn engine.** Creates `Process`, wires `Pipe` stdio, reads stdout/stderr in detached `Task`, routes output lines to `eventSink`, terminates with SIGTERM → SIGKILL escalation |
| `Sources/Panels/AgentSessionRunningSession.swift` | `final class AgentSessionRunningSession` | Per-session state: `process`, `stdin`, `inputWriter`, `codexAppServerSession`, `openCodeBaseURL/SessionID`, `pendingExitStatus`, `drainedStreams`, line-buffer accumulators |
| `Sources/Panels/AgentSessionPanel.swift` | `@MainActor final class AgentSessionPanel: Panel` | Panel model: owns `AgentSessionWebRendererSession`; `panelType == .agentSession` |
| `Sources/Panels/AgentSessionBridge.swift` | `enum AgentSessionBridgeContract` | Defines `handlerName = "agentSession"` — the WKWebView script message handler name |
| `Sources/Panels/AgentSessionWebRenderer.swift` | `struct AgentSessionWebRenderer: NSViewRepresentable` | SwiftUI wrapper; calls `panel.rendererSession.coordinator(…).ensureWebView(…)` and attaches it |
| `Sources/Panels/AgentSessionWebRendererCoordinator.swift` | `@MainActor final class AgentSessionWebRendererCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply` | Owns one `AgentSessionProcessStore`; bridges JS↔Swift; dispatches `WKScriptMessage` requests to `processStore.start/writeLine/stop` |
| `Sources/Panels/AgentSessionWebRendererSession.swift` | `@MainActor final class AgentSessionWebRendererSession` | Thin wrapper so one coordinator survives view lifecycle churn |
| `Sources/AgentForkSupport.swift` | `enum AgentForkSupport` | Checks whether opencode version supports fork (`>= 1.14.50`); runs version probe sub-process via `ProcessTerminationGate` with 3-second timeout + 500ms SIGKILL escalation |
| `Sources/AgentHibernation/AgentHibernationLifecycleState.swift` | `enum AgentHibernationLifecycleState` | States: `.unknown`, `.running`, `.idle`, `.needsInput`; `.idle` triggers hibernation; `AgentHibernationLifecycleStatusKeys.allowedStatusKeys` lists all recognized agents |
| `Sources/RestorableAgentSession.swift` | (session restore helpers) | Shell quoting (`TerminalStartupShellQuoting`), working-directory prefix injection (`TerminalStartupWorkingDirectoryPrefix`) |
| `Sources/RestorableAgentTypes.swift` | `enum RestorableAgentKind` | Broader agent taxonomy for Vault session index: `.claude`, `.codex`, `.grok`, `.pi`, `.amp`, `.cursor`, `.gemini`, `.kiro`, `.antigravity`, `.opencode`, `.rovodev`, `.hermesAgent`, `.copilot`, `.codebuddy`, `.factory`, `.qoder`, `.custom(String)` |
| `Sources/AgentSessionRendererKind.swift` | `enum AgentSessionRendererKind` | `.react` → `markdown-viewer/webviews-app/agent-session.html`; `.solid` → `agent-session-solid/index.html` |
| `Packages/macOS/CMUXAgentLaunch/` | Swift package | `AgentLaunchEnvironmentPolicy`, `AgentLaunchSanitizer`, `AgentResumeArgv`, `CodexSessionResolver`, `HermesAgentCodexEnvironment`, Vault/Workstream types. Imported as `CMUXAgentLaunch` throughout the app target. |

### AgentSessionProvider

```swift
// Sources/AgentSessionProvider.swift
enum AgentSessionProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex      // transport: "stdio-jsonrpc", args: ["app-server", "--listen", "stdio://"]
    case claude     // transport: "stdio-jsonl",   args: ["-p", "--output-format", "stream-json", …]
    case opencode   // transport: "http-loopback",  args: ["serve", "--hostname", "127.0.0.1", "--port", "0", "--print-logs"]
}
```

`shouldAutoStartSession` is `true` for codex and opencode (session starts at launch);
`false` for claude (session only starts when user sends a prompt).

### AgentSessionLaunchPlan

```swift
// Sources/AgentSessionLaunchPlan.swift
struct AgentSessionLaunchPlan: Equatable, Sendable {
    let provider: AgentSessionProviderID
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]

    func environment(overridingWorkingDirectory workingDirectory: String?) -> [String: String]
    // Injects PWD; generates OPENCODE_SERVER_PASSWORD UUID for opencode
}
```

### AgentExecutableResolver

```swift
// Sources/AgentExecutableResolver.swift
struct AgentExecutableResolver {
    var environment: [String: String]         // defaults to ProcessInfo.processInfo.environment
    var fileManager: FileManager
    var bundleResourceURL: URL?
    var extraSearchDirectories: [String]
    var includeStandardSearchDirectories: Bool // adds /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin
    var configuredExecutablePaths: [AgentSessionProviderID: String]

    func resolve(_ provider: AgentSessionProviderID) throws -> AgentSessionLaunchPlan
    func resolvedSearchDirectories() -> [String]
    static func cmuxConfiguredExecutablePaths(defaults: UserDefaults) -> [AgentSessionProviderID: String]
}
```

Search order: configured path override → `PATH` → `extraSearchDirectories` → user
runtime dirs (~/.local/bin, ~/.bun/bin, nvm/volta/fnm/mise/asdf paths) → standard
dirs. Skips cmux shim directories (`CMUX_CLAUDE_WRAPPER_SHIM*`, `/tmp/cmux-cli-shims`)
and bundled wrappers (reads first 512 bytes to detect the cmux claude wrapper sentinel).

### AgentSessionRendererKind

```swift
// Sources/AgentSessionRendererKind.swift
enum AgentSessionRendererKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case react   // → Resources/markdown-viewer/webviews-app/agent-session.html
    case solid   // → Resources/agent-session-solid/index.html
}
```

The HTML shells use `window.webkit.messageHandlers.agentSession.postMessage(…)` to call
back into Swift, where `AgentSessionWebRendererCoordinator` handles the message.

### AgentHibernation

```swift
// Sources/AgentHibernation/AgentHibernationLifecycleState.swift
enum AgentHibernationLifecycleState: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown, running, idle, needsInput

    var allowsHibernation: Bool { self == .idle }
}

enum AgentHibernationLifecycleStatusKeys {
    // Agents that publish lifecycle state via the cmux socket status protocol:
    static let allowedStatusKeys: Set<String> = [
        "amp", "antigravity", "claude_code", "codebuddy", "codex", "copilot",
        "cursor", "factory", "gemini", "grok", "hermes-agent", "kiro",
        "opencode", "pi", "qoder", "rovodev"
    ]
}
```

Agents publish their lifecycle state to the workspace sidebar via the socket
status/PID protocol. When state == `.idle`, the app may hibernate (kill) the process
and restart it later. The Vault panel
(`Sources/SessionIndexView.swift`, `Sources/SessionIndexStore.swift`) tracks these
across sessions.

### Ghostty Surface Creation

Each `TerminalPanel` wraps a `TerminalSurface` (from `Packages/macOS/CmuxTerminal/`).
A Ghostty surface is created in:

```
Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+RuntimeSurfaceCreation.swift
```

Key function: `createNativeRuntimeSurface(app:for:scaleFactors:claudeShim:) -> (ghostty_surface_t?, String?)`.

Ghostty is a C library wrapped via `ghostty.h` and built as `GhosttyKit.xcframework`
(a submodule at `ghostty/`). The surface config accepts an `NSView` pointer
(`platform.macos.nsview`) and a userdata pointer to `GhosttySurfaceCallbackContext`.

Environment injected at surface creation time (managed by cmux):
- `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH` (control socket)
- `CMUX_PORT`, `CMUX_PORT_END`, `CMUX_PORT_RANGE` (per-workspace port range)
- `CMUX_BUNDLED_CLI_PATH`, `CMUX_BUNDLE_ID`
- `CMUX_CLAUDE_HOOKS_DISABLED`, `CMUX_CUSTOM_CLAUDE_PATH` (spawn policy)
- `CLAUDE_CONFIG_DIR` (if set in the host environment)

`AgentSessionPanel` panes do **not** go through Ghostty at all — they use a WKWebView.

### Recommended Hook Points for Regatta

### (a) Spawn an agent process in a pane at a given working dir

`AgentSessionProcessStore.start(plan:workingDirectory:)` is the authoritative spawn
call (line ~19 in `Sources/Panels/AgentSessionProcessStore.swift`):

```swift
func start(plan: AgentSessionLaunchPlan, workingDirectory: String?) async throws -> AgentSessionStartedSession
```

To spawn from Regatta without the WKWebView shell:
1. Create an `AgentExecutableResolver` (or use a hard-coded `executableURL`).
2. Call `resolver.resolve(.claude)` (or `.codex` / `.opencode`) to get an
   `AgentSessionLaunchPlan`.
3. Instantiate `AgentSessionProcessStore()` and wire `eventSink` for output.
4. Call `await processStore.start(plan: plan, workingDirectory: "/path/to/repo")`.
5. Send input via `processStore.writeLine(sessionId:text:)`.

If you want the process visible inside a workspace split, create an `AgentSessionPanel`
(which carries its own `AgentSessionWebRendererSession`) and add it to the workspace
`panels` dict + `bonsplitController`. The coordinator calls
`processStore.start(plan:workingDirectory:)` internally when the WKWebView sends the
`provider.start` script message.

### (b) Observe output

Wire `AgentSessionProcessStore.eventSink`:

```swift
processStore.eventSink = { event in
    // event["type"] is one of:
    //   "provider.started"    → event["sessionId"], ["providerId"], ["executablePath"], ["arguments"]
    //   "provider.output"     → event["sessionId"], ["providerId"], ["stream"] ("stdout"|"stderr"), ["text"]
    //   "provider.activity"   → event["sessionId"], ["providerId"], + provider-specific keys
    //   "provider.turnComplete" → event["sessionId"], ["providerId"]
    //   "provider.exit"       → event["sessionId"], ["providerId"], ["status"] (Int32)
}
```

For claude (`.stdio-jsonl` transport), raw stdout lines are JSONL. The
`ClaudeStreamJSONAccumulator` (in `Sources/Panels/ClaudeStreamJSONAccumulator.swift`)
strips partial streaming deltas and emits final text segments; the coordinator uses it
before forwarding to the WKWebView. Regatta can use the same accumulator or consume
raw JSONL.

For opencode (`.http-loopback` transport), the process announces its base URL on
stderr (`"opencode server listening on <url>"`); the store then POST-creates a session
and subscribes to its Server-Sent Events stream.

For codex (`.stdio-jsonrpc` transport), `CodexAppServerSession` mediates the protocol.

### (c) Kill it

```swift
// Graceful (SIGTERM, escalates to SIGKILL after 3 seconds):
try processStore.stop(sessionId: sessionId)

// Kill all sessions on a store:
processStore.closeAll()
```

`requestTermination(for:)` sends `process.terminate()` (SIGTERM) then installs a
`DispatchSourceTimer` that fires SIGKILL after
`AgentSessionProcessStore.terminationEscalationInterval` (3 seconds).

---

## Seam 3: Tabs / Workspaces / Sidebar

### Key Files and Types

| File | Type | Role |
|------|------|------|
| `Sources/TabManager.swift` | `TabManager` (`@MainActor ObservableObject`) | Ordered workspace list, focus, window title, sidebar git hosting, notification dismissal |
| `Sources/Workspace.swift` | `final class Workspace: Identifiable, ObservableObject` | One tab; owns `bonsplitController`, `panels`, sidebar metadata, git/PR state |
| `Sources/CmuxWorkspaceDefinition.swift` | `struct CmuxWorkspaceDefinition: Codable` | Decoded from `~/.config/cmux/cmux.json` workspace entries; carries `name`, `cwd`, `color`, `env`, `layout` |
| `Sources/Sidebar/SidebarState.swift` | `SidebarState: ObservableObject` | `isVisible: Bool`, `persistedWidth: CGFloat` |
| `Sources/RightSidebarPanelView.swift` | `enum RightSidebarMode` | Modes: `.files`, `.find`, `.sessions`, `.feed`, `.dock` (`.sessions` label = "Vault") |
| `Sources/SessionIndexView.swift` | `SessionIndexView` | Vault / session index panel UI |
| `Sources/SessionIndexStore.swift` | `SessionIndexStore` | Persists restoring agent sessions across launches; backed by SQLite for codex sessions |
| `Sources/SidebarWorkspaceGroupHeaderView.swift` / `Sources/SidebarWorkspaceRenderItem.swift` | Sidebar rendering | Left sidebar workspace list |
| `Sources/TabManager+SidebarGitHosting.swift` | extension | Observes git branch + pull request state per workspace |

### Per-tab Metadata Available

All properties are on `Workspace` (observable on `@MainActor`):

| Property | Type | Source |
|----------|------|--------|
| `id` | `UUID` | Stable workspace ID |
| `title`, `customTitle` | `String?` | User rename / AI auto-naming |
| `currentDirectory` | `String` | Updated by terminal cwd-change notifications |
| `gitBranch` | `SidebarGitBranchState?` | `{ branch: String, isDirty: Bool }` — from `TabManager+SidebarGitHosting` |
| `pullRequest` | `SidebarPullRequestState?` | PR number/URL from `TabManager.pullRequestProbing` |
| `statusEntries` | `[String: SidebarStatusEntry]` | Agent lifecycle status published via the control socket (key = agent name, e.g. `"claude_code"`) |
| `agentPIDs` | `[String: pid_t]` | PIDs reported by agents via the control socket |
| `listeningPorts` | `[Int]` | Local ports the workspace is listening on |
| `surfaceListeningPorts` | `[UUID: [Int]]` | Per-panel listening ports |
| `remoteConfiguration`, `remoteConnectionState` | various | SSH remote workspace state |
| `workspaceEnvironment` | `[String: String]` | User-defined env vars applied to every shell in this workspace |
| `portOrdinal` | `Int` | Used to assign `CMUX_PORT` range (per-workspace, per-session) |
| `panels` | `[UUID: any Panel]` | All panels currently in this workspace |

`Workspace` publishes changes via `objectWillChange`; observe with Combine or SwiftUI.

`TabManager` exposes `tabsPublisher: CurrentValueSubject<[Workspace], Never>` and
`tabs: [Workspace]`.

---

## Seam 4: Build & Test

### Xcode Scheme(s)

| Scheme | Use |
|--------|-----|
| `cmux` | Default — builds app + UI tests (`cmuxUITests`); launch config is Release |
| `cmux-unit` | Unit tests only — builds app + `cmuxTests.xctest`; launch config is Debug (`ignoresPersistentStateOnLaunch="YES"`) |
| `cmux-ci` | CI scheme |

All schemes are in `cmux.xcodeproj/xcshareddata/xcschemes/`.

### Test Target(s)

| Target | Files |
|--------|-------|
| `cmuxTests` | `cmuxTests/` — 100+ unit-test files; blueprint ID `F1000004A1B2C3D4E5F60718` |
| `cmuxUITests` | `cmuxUITests/` — UI integration tests; blueprint ID `CB450DF0F0B3839599082C4D` |

Test files **must** be wired into `cmux.xcodeproj/project.pbxproj` (both a
`PBXFileReference` and a `PBXSourcesBuildPhase` entry). The CI job
`workflow-guard-tests` runs `./scripts/lint-pbxproj-test-wiring.sh` to enforce this.

### Build Commands

**Tagged Debug build (required during development — do not use bare xcodebuild):**
```bash
./scripts/reload.sh --tag <your-branch-slug>
# e.g.
./scripts/reload.sh --tag regatta-pane-bridge
```

**Compile-only check (no app launch):**
```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-<your-tag> build
```

**Rebuild GhosttyKit (when ghostty submodule changes):**
```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

### Test Commands

**Run unit tests (cmuxTests scheme):**
```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux-unit \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/cmux-test
```

**Run a single test class:**
```bash
xcodebuild test -project cmux.xcodeproj -scheme cmux-unit \
  -destination 'platform=macOS' \
  -only-testing:cmuxTests/AgentSessionSocketSurfaceTests \
  -derivedDataPath /tmp/cmux-test
```

**Dogfood CLI against a tagged Debug build:**
```bash
CMUX_TAG=regatta-pane-bridge scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=regatta-pane-bridge scripts/cmux-debug-cli.sh send \
  --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper sets `CMUX_SOCKET_PATH` to `/tmp/cmux-debug-<tag>.sock` and refuses to run
without `CMUX_TAG` to prevent collisions with the main app.
