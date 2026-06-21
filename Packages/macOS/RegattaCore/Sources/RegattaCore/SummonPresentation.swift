/// The pure presentation state of the Summon overlay (issue #17).
///
/// Models whether the worker-terminal grid is filling the main work area and
/// applies the user intents that change that — summoning the grid, dismissing it
/// with `esc`, and toggling it from a Fleet click. It is a value type with no UI
/// and no actor reference, so the overlay view-model can drive it and tests can
/// assert every intent transition without SwiftUI.
///
/// ## Why a separate state type
/// Dismiss (`esc`) must leave the underlying work untouched: the overlay is a
/// pure view layer over the main area, so "dismiss" only flips this flag back to
/// hidden. Keeping the flag and its transitions here makes that contract testable
/// in isolation from the live terminal hosting.
public struct SummonPresentation: Sendable, Equatable {

    /// Whether the overlay grid is currently filling the main work area.
    public private(set) var isPresented: Bool

    /// Creates a presentation state.
    ///
    /// - Parameter isPresented: Whether the overlay starts visible. Defaults to
    ///   `false` (normal work, brain still in the rail).
    public init(isPresented: Bool = false) {
        self.isPresented = isPresented
    }

    /// Shows the overlay grid (e.g. a Fleet worker click or expand control).
    public mutating func summon() {
        isPresented = true
    }

    /// Hides the overlay grid, returning to normal work. Triggered by `esc`.
    ///
    /// Dismissing only flips the presentation flag; the underlying work and the
    /// live worker processes are untouched.
    public mutating func dismiss() {
        isPresented = false
    }

    /// Toggles the overlay between shown and hidden.
    public mutating func toggle() {
        isPresented.toggle()
    }
}
