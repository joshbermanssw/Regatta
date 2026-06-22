import SwiftUI

/// The bottom-right toast stack rendered over the main work area.
///
/// Reads the live ``RegattaToastCenter/toasts`` snapshot **above** its `ForEach`
/// and passes value copies plus a dismiss closure into rows (snapshot-boundary
/// rule). The container is pass-through: only the toast cards themselves take hit
/// tests, so the work area underneath stays fully interactive.
struct RegattaToastOverlayView: View {
    /// The app-lifetime center, injected for testability; defaults to the shared
    /// instance.
    let center: RegattaToastCenter

    init(center: RegattaToastCenter = .shared) {
        self.center = center
    }

    var body: some View {
        // Snapshot the queue above the ForEach so no center reference crosses the
        // list boundary.
        let toasts = center.toasts

        return VStack(alignment: .trailing, spacing: 8) {
            Spacer(minLength: 0)
            ForEach(toasts) { toast in
                RegattaToastRowView(toast: toast) {
                    center.dismiss(toast.id)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        // Pass-through: the container does not eat clicks; only the cards do.
        .allowsHitTesting(true)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: toasts)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RegattaToastOverlay")
    }
}
