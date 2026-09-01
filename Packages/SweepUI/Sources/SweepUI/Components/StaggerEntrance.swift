import SwiftUI

/// Staggered results entrance (PLAN §5 volume-raise): each row in a freshly-landed list fades and
/// lifts in `SweepTokens.staggerStep` after the one before it, capped at `SweepTokens.staggerCap`
/// rows so a long list does not take seconds to finish appearing. A spring, not a fixed-duration
/// animation — `.delay` only pushes back when it *starts*; retargeting mid-flight still works the
/// normal way once it does.
private struct StaggerEntrance: ViewModifier {
    let index: Int
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
            .onAppear {
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(SweepMotion.row.delay(SweepMotion.staggerDelay(index))) {
                        appeared = true
                    }
                }
            }
    }
}

extension View {
    /// Apply to each row of a `ForEach` with that row's index, right after a result set lands.
    /// Not for rows that were already on screen (a filter narrowing an existing list, a "Show
    /// all" page) — those should not visibly re-enter every time selection or search changes.
    public func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggerEntrance(index: index))
    }
}
