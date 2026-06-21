import SwiftUI
import Foundation
import RegattaFleet
import RegattaGitHub

// MARK: - FleetSectionView

/// The Fleet rail section: a "hand to Regatta" action plus the list of
/// persistent PR shepherd cards, driven by ``RegattaFleetViewModel``.
///
/// ## Handoff
/// When the active tab is attached to a PR, the header shows a "Hand to Regatta"
/// button. Tapping it resolves the PR from the injected `contextProvider` and
/// hands it off to the ``Fleet``, creating a persistent shepherd. Handing the
/// same PR off again is idempotent (no duplicate).
///
/// ## Shepherd card (#33)
/// Each shepherd renders as a ``ShepherdCard`` showing the watched PR's live CI
/// checks (with any running ci-fix loop), the review threads with per-thread
/// status, an activity log of actions taken, and the per-PR autonomy toggle plus
/// pending approvals. The card binds to a value-typed ``ShepherdCardModel``
/// projected from ``ShepherdState`` + the view model's activity / fix-loop seams.
///
/// ## Snapshot-boundary rule (CLAUDE.md)
/// State is read from the `@Observable` view-model at this level and passed as
/// **value snapshots** (`ShepherdCardModel` is a `struct`) into ``ShepherdCard``
/// — no view-model or `Fleet` reference escapes the `ForEach`.
///
/// ## No state mutation in body
/// The handoff is triggered only from a `Button` action; the `contextProvider`
/// closure is never called from `body`.
struct FleetSectionView: View {
    let viewModel: RegattaFleetViewModel
    /// Returns the active workspace context (incl. its PR) when the handoff
    /// button is tapped. `@MainActor`-isolated because the source of truth
    /// (`TabManager.selectedWorkspace`) is main-actor-bound. `nil` disables the
    /// handoff affordance.
    let contextProvider: (@MainActor () -> AttachedTabContext?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            handoffButton
            shepherdList
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            viewModel.observe()
        }
    }

    // MARK: - Handoff button

    @ViewBuilder
    private var handoffButton: some View {
        if contextProvider != nil {
            Button {
                handoffActiveTab()
            } label: {
                Label(
                    String(localized: "fleet.handoff.label", defaultValue: "Hand PR to Regatta"),
                    systemImage: "sailboat.fill"
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("FleetHandoffButton")
            .accessibilityLabel(
                String(localized: "fleet.handoff.a11y", defaultValue: "Hand the active tab's pull request to Regatta")
            )
            .help(String(localized: "fleet.handoff.tooltip", defaultValue: "Create a persistent shepherd that watches this PR's CI and reviews"))
        }
    }

    // MARK: - Shepherd list

    /// The list of persistent shepherd cards.
    ///
    /// Snapshot-boundary: each card's ``ShepherdCardModel`` is projected here
    /// (before the `ForEach`) as an immutable value. Cards receive value copies +
    /// closures only — no view-model or `Fleet`/`AutonomyGate` reference escapes
    /// into the list subtree.
    private var shepherdList: some View {
        let cards: [ShepherdCardModel] = viewModel.shepherds.map { shepherd in
            ShepherdCardModel(
                state: shepherd,
                pending: viewModel.pendingActions.filter {
                    $0.pullRequest.id == shepherd.pullRequest.id
                },
                activity: viewModel.activity(for: shepherd.pullRequest),
                fixLoop: viewModel.fixLoop(for: shepherd.pullRequest)
            )
        }

        return Group {
            if cards.isEmpty {
                emptyView
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(cards) { card in
                        let ref = card.state.pullRequest
                        ShepherdCard(
                            model: card,
                            actions: ShepherdCardActions(
                                onDismiss: { dismiss(ref) },
                                onSetMode: { mode in setMode(mode, for: ref) },
                                onApprove: { id in approve(id) },
                                onReject: { id in reject(id) }
                            )
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    private var emptyView: some View {
        Text(String(localized: "fleet.empty", defaultValue: "No shepherds yet"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    // MARK: - Actions

    /// Resolves the active tab's PR and hands it off. Called only from a button.
    private func handoffActiveTab() {
        guard
            let ctx = contextProvider?(),
            let pr = ctx.pullRequest,
            let ref = PullRequestRef.parse(label: pr.label, number: pr.number)
        else { return }
        viewModel.handoff(ref)
    }

    private func dismiss(_ ref: PullRequestRef) {
        viewModel.dismiss(ref)
    }

    private func setMode(_ mode: AutonomyMode, for ref: PullRequestRef) {
        viewModel.setAutonomyMode(mode, for: ref)
    }

    private func approve(_ id: UUID) {
        viewModel.approve(id)
    }

    private func reject(_ id: UUID) {
        viewModel.reject(id)
    }
}

// MARK: - ShepherdCardActions

/// The closure bundle passed to a ``ShepherdCard``. Keeps the snapshot-boundary
/// contract: cards hold value snapshots + this bundle of actions, never a store
/// reference.
struct ShepherdCardActions {
    let onDismiss: () -> Void
    let onSetMode: (AutonomyMode) -> Void
    let onApprove: (UUID) -> Void
    let onReject: (UUID) -> Void
}
