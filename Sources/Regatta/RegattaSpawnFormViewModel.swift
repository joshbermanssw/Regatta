import Foundation
import Observation
import RegattaCore

/// Drives the Fleet "Spawn worker" form: a sheet that lets the user pick a real
/// repository, enter a task, and choose an agent provider, then spawns a worker
/// with a real ``WorkerSpec`` instead of the old placeholder that ran `claude` in
/// `/` and instantly failed.
///
/// ## Why a view-model
/// The pure decision logic (default repo from context, required-prompt gating,
/// git-repo validation, spec building) lives in ``RegattaSpawnForm`` in
/// ``RegattaCore`` and is unit-tested there with no UI. This `@MainActor
/// @Observable` adapter holds the editable ``form`` for SwiftUI bindings, surfaces
/// an inline ``validationError``, and performs the side-effecting spawn (orchestrator
/// + toast) when the user taps Spawn.
///
/// ## Testability seam
/// The spawn action is injected as a closure (`spawn`) rather than reaching into a
/// global orchestrator, so the gating/validation/spec-building behavior is verified
/// headlessly. Production wiring passes a closure that calls
/// `RegattaFleetManager.shared.orchestrator.spawnWorker`.
@MainActor
@Observable
final class RegattaSpawnFormViewModel: Identifiable {

    /// A stable identity so the form can drive `.sheet(item:)`.
    nonisolated let id = UUID()

    // MARK: - Observable form state

    /// The editable form, bound field-by-field by ``RegattaSpawnFormView``.
    var form: RegattaSpawnForm

    /// An inline validation message shown beneath the repo field, or `nil` when the
    /// repo is valid / not yet validated.
    private(set) var validationError: String?

    /// Whether the Spawn button should be enabled (non-empty prompt + repo path).
    var canSpawn: Bool { form.canSpawn }

    /// The providers offered by the picker, in display order.
    var providers: [AgentProviderID] { AgentProviderID.allCases }

    // MARK: - Non-observable dependencies

    /// The git-repository probe used to validate the chosen path at spawn time.
    @ObservationIgnored
    private let probe: any RegattaGitRepositoryProbe

    /// The side-effecting spawn action: builds nothing itself, just launches the
    /// given validated spec. Injected so the view-model is testable without the
    /// global orchestrator actor.
    @ObservationIgnored
    private let spawn: @MainActor (WorkerSpec) -> Void

    /// The toast center for spawn success / invalid-repo feedback.
    @ObservationIgnored
    private let toasts: RegattaToastCenter

    // MARK: - Init

    /// Creates a spawn-form view-model.
    ///
    /// - Parameters:
    ///   - contextDirectory: The active tab's current working directory, used as the
    ///     default repository. `nil` falls back to the home directory.
    ///   - probe: The git-repository probe. Defaults to the filesystem probe.
    ///   - toasts: The toast center for feedback. Defaults to the shared instance.
    ///   - spawn: The side-effecting spawn action invoked with the built
    ///     ``WorkerSpec``. Defaults to launching via the app-lifetime orchestrator.
    init(
        contextDirectory: String?,
        probe: any RegattaGitRepositoryProbe = FileSystemGitRepositoryProbe(),
        toasts: RegattaToastCenter = .shared,
        spawn: (@MainActor (WorkerSpec) -> Void)? = nil
    ) {
        self.form = RegattaSpawnForm.makeDefault(contextDirectory: contextDirectory)
        self.probe = probe
        self.toasts = toasts
        self.spawn = spawn ?? RegattaSpawnFormViewModel.defaultSpawn
    }

    // MARK: - Intents

    /// Clears the inline validation error (called when the repo path is edited so a
    /// stale "not a git repo" message disappears as the user types).
    func clearValidationError() {
        validationError = nil
    }

    /// Validates the form and, on success, spawns a worker and returns `true` so the
    /// view can dismiss the sheet. On failure, sets ``validationError`` / emits an
    /// error toast and returns `false` so the sheet stays open.
    ///
    /// - Returns: `true` when a worker was spawned and the sheet should close.
    @discardableResult
    func spawnWorker() -> Bool {
        let resolvedRepo: URL
        do {
            resolvedRepo = try form.validatedRepoURL(using: probe)
        } catch let error as RegattaSpawnFormError {
            handle(error)
            return false
        } catch {
            validationError = String(
                localized: "regatta.spawnForm.error.generic",
                defaultValue: "Couldn't validate the repository."
            )
            return false
        }

        validationError = nil
        let spec = form.makeSpec(repoURL: resolvedRepo)
        spawn(spec)
        toasts.success(
            String(localized: "regatta.toast.worker.spawned.title", defaultValue: "Worker spawned"),
            spec.name
        )
        return true
    }

    // MARK: - Error handling

    private func handle(_ error: RegattaSpawnFormError) {
        switch error {
        case .emptyPrompt:
            // The button is disabled in this state; surface a toast defensively.
            toasts.error(
                String(localized: "regatta.spawnForm.error.emptyPrompt", defaultValue: "Enter a task before spawning.")
            )
        case .emptyRepoPath:
            validationError = String(
                localized: "regatta.spawnForm.error.emptyRepo",
                defaultValue: "Choose a working directory."
            )
        case .notAGitRepository(let path):
            let message = String.localizedStringWithFormat(
                String(
                    localized: "regatta.spawnForm.error.notGitRepo",
                    defaultValue: "%@ isn't a git repository."
                ),
                path
            )
            validationError = message
            toasts.error(
                String(localized: "regatta.spawnForm.error.notGitRepo.toast.title", defaultValue: "Not a git repository"),
                path
            )
        }
    }

    // MARK: - Default spawn

    /// The production spawn action: launches the spec through the app-lifetime
    /// orchestrator. Detached as a `static` so it isn't captured before `self` is
    /// fully initialized.
    @MainActor
    private static func defaultSpawn(_ spec: WorkerSpec) {
        let orchestrator = RegattaFleetManager.shared.orchestrator
        Task {
            _ = await orchestrator.spawnWorker(spec)
        }
    }
}
