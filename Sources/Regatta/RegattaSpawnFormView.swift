import SwiftUI
import AppKit
import RegattaCore

/// The Fleet "Spawn worker" form sheet: pick a real repository, enter a task, and
/// choose an agent provider, then spawn a worker with a real ``WorkerSpec``.
///
/// Replaces the old placeholder spawn (which ran `claude` in `/` and instantly
/// failed). Defaults the working directory to the active tab's repository via
/// ``RegattaSpawnFormViewModel``.
///
/// ## No state mutation in body
/// All side effects (folder picker, spawn) run from button actions. The view binds
/// to the view-model's ``RegattaSpawnFormViewModel/form`` for the fields and reads
/// ``RegattaSpawnFormViewModel/validationError`` for inline feedback; it never
/// mutates store state inside `body`.
struct RegattaSpawnFormView: View {
    let viewModel: RegattaSpawnFormViewModel

    /// Dismisses the form. Invoked on Cancel, on a successful spawn, and on `esc`.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            repoField
            promptField
            providerPicker
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(width: 440)
        .frame(minHeight: 380)
        .background(.regularMaterial)
        .accessibilityIdentifier("RegattaSpawnForm")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sailboat")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(String(localized: "regatta.spawnForm.title", defaultValue: "Spawn worker"))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
        }
    }

    // MARK: - Repo field

    private var repoField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "regatta.spawnForm.repo.label", defaultValue: "Working directory"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(
                    String(localized: "regatta.spawnForm.repo.placeholder", defaultValue: "Path to a git repository"),
                    text: Binding(
                        get: { viewModel.form.repoPath },
                        set: { newValue in
                            viewModel.form.repoPath = newValue
                            viewModel.clearValidationError()
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityIdentifier("RegattaSpawnFormRepoField")

                Button {
                    chooseFolder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .help(String(localized: "regatta.spawnForm.repo.choose.help", defaultValue: "Choose a folder"))
                .accessibilityLabel(String(localized: "regatta.spawnForm.repo.choose.a11y", defaultValue: "Choose working directory"))
            }
            if let error = viewModel.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("RegattaSpawnFormRepoError")
            }
        }
    }

    // MARK: - Prompt field

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "regatta.spawnForm.prompt.label", defaultValue: "Task"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { viewModel.form.prompt },
                set: { viewModel.form.prompt = $0 }
            ))
            .font(.system(size: 12))
            .frame(minHeight: 90)
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .accessibilityIdentifier("RegattaSpawnFormPromptField")
            Text(String(localized: "regatta.spawnForm.prompt.hint", defaultValue: "What should this worker do?"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Provider picker

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "regatta.spawnForm.provider.label", defaultValue: "Agent"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker(
                selection: Binding(
                    get: { viewModel.form.providerID },
                    set: { viewModel.form.providerID = $0 }
                )
            ) {
                ForEach(viewModel.providers, id: \.self) { provider in
                    // Provider names are product brand names, shown verbatim.
                    Text(provider.displayName).tag(provider)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("RegattaSpawnFormProviderPicker")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button(role: .cancel) {
                onClose()
            } label: {
                Text(String(localized: "regatta.spawnForm.cancel", defaultValue: "Cancel"))
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("RegattaSpawnFormCancelButton")

            Button {
                if viewModel.spawnWorker() {
                    onClose()
                }
            } label: {
                Text(String(localized: "regatta.spawnForm.spawn", defaultValue: "Spawn"))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSpawn)
            .accessibilityIdentifier("RegattaSpawnFormSpawnButton")
        }
    }

    // MARK: - Folder picker

    /// Presents an `NSOpenPanel` to choose the working directory. Called only from a
    /// button action.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "regatta.spawnForm.repo.choose.prompt", defaultValue: "Choose")
        panel.message = String(
            localized: "regatta.spawnForm.repo.choose.message",
            defaultValue: "Choose a git repository for the worker."
        )
        let current = viewModel.form.trimmedRepoPath
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.form.repoPath = url.path
            viewModel.clearValidationError()
        }
    }
}
