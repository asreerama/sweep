import SwiftUI

public enum ScanRingState: Sendable, Equatable {
    case idle
    case scanning
    case complete
}

/// Set false while the window is occluded or minimised, to stop the sweep turning where nobody
/// can see it. Efficiency contract, PLAN §5.
public struct SweepAnimationsEnabledKey: EnvironmentKey {
    public static let defaultValue = true
}

extension EnvironmentValues {
    public var sweepAnimationsEnabled: Bool {
        get { self[SweepAnimationsEnabledKey.self] }
        set { self[SweepAnimationsEnabledKey.self] = newValue }
    }
}

/// The scan ring. Motion moment one.
///
/// Two modes, selected by whether the caller can report a determinate `progress` fraction:
///
/// - **Determinate** (`progress` non-nil — the Smart Scan / System Junk hero): a thick, faint
///   track and a bold indigo→violet gradient arc that grows to `progress` with a soft static
///   glow behind it. Nothing travels, spins or pulses while scanning — the only motion is the arc
///   filling and the number rolling. This is the "Minimal" treatment: the confident thickness and
///   color volume without a distracting moving element.
/// - **Indeterminate** (`progress` nil — the smaller secondary-screen scan indicators): the
///   original turning conic comet, kept for callers with no fraction to show.
///
/// Both land the same way: on completion the arc closes to a full circle and the ring gives one
/// settle-and-release pulse. Under Reduce Motion nothing turns or scales.
public struct ScanRing<Content: View>: View {
    private let state: ScanRingState
    private let diameter: CGFloat
    /// A 0…1 scan fraction, or `nil` for an indeterminate spinner. Only ever grows while scanning;
    /// `state == .complete` overrides it to a full ring regardless.
    private let progress: Double?
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sweepAnimationsEnabled) private var animationsEnabled
    /// Monotonically increasing — never reset to 0 — so stopping never has to snap back across a
    /// discontinuity. A `repeatForever` rotation (the original approach) cannot do this: SwiftUI
    /// gives no way to read a repeating animation's live interpolated value, so there is nothing
    /// to decelerate *from*. Bumping a real, ever-growing angle by exactly 360° every
    /// `sweepPeriod` looks identical while spinning, and leaves a genuine current value to ease
    /// out from when the scan lands (PLAN §5, "Motion continuity": no snap, decelerate to rest).
    @State private var rotationAngle: Double = 0
    @State private var spinTask: Task<Void, Never>?
    @State private var pulseScale: CGFloat = 1

    public init(
        state: ScanRingState,
        diameter: CGFloat = 240,
        progress: Double? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.diameter = diameter
        self.progress = progress
        self.content = content()
    }

    /// One thick weight for both the track and the arc, so the fill reads as filling the same
    /// channel the track carves — the "confident, thick" look, replacing the old hairline stroke.
    private var trackWidth: CGFloat { max(3, diameter * 0.075) }
    private var sweepWidth: CGFloat { max(3, diameter * 0.075) }

    private var isDeterminate: Bool { progress != nil }

    /// How much of the ring the determinate arc draws. `.complete` always shows a full circle so a
    /// scan whose fraction lands a hair short of 1 still closes cleanly.
    private var shownFraction: CGFloat {
        switch state {
        case .idle: 0
        case .complete: 1
        case .scanning: CGFloat(min(max(progress ?? 0, 0), 1))
        }
    }

    public var body: some View {
        ZStack {
            Circle()
                .strokeBorder(SweepTokens.accent.opacity(0.14), lineWidth: trackWidth)

            if isDeterminate {
                determinateArc
            } else if reduceMotion {
                reducedIndicator
            } else {
                comet
            }

            // The self-drawing completion ring belongs to the indeterminate path only; the
            // determinate arc closes itself by trimming to 1 on `.complete`.
            if !isDeterminate {
                settledRing
            }

            content
                .frame(maxWidth: diameter * 0.74)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.ring, value: state)
        .onAppear { syncTurning() }
        .onChange(of: state) { _, _ in
            syncTurning()
            pulseOnCompletion()
        }
        .onChange(of: animationsEnabled) { _, _ in syncTurning() }
        .onChange(of: reduceMotion) { _, _ in syncTurning() }
        .onDisappear { spinTask?.cancel() }
        .accessibilityHidden(true)
    }

    // MARK: - Layers

    /// The "Minimal" determinate arc: a soft accent bloom behind a crisp indigo→violet gradient
    /// stroke, both trimmed to `shownFraction`. It grows as the scan reports progress and closes to
    /// a full circle on completion; the one completion pulse rides on `pulseScale`.
    private var determinateArc: some View {
        ZStack {
            Circle()
                .inset(by: sweepWidth / 2)
                .trim(from: 0, to: shownFraction)
                .stroke(SweepTokens.accent, style: StrokeStyle(lineWidth: sweepWidth * 1.15, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .blur(radius: sweepWidth * 0.7)
                .opacity(0.5)
            Circle()
                .inset(by: sweepWidth / 2)
                .trim(from: 0, to: shownFraction)
                .stroke(SweepTokens.ringArc, style: StrokeStyle(lineWidth: sweepWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .scaleEffect(pulseScale)
        .animation(reduceMotion ? SweepMotion.crossfade : .easeOut(duration: 0.32), value: shownFraction)
    }

    /// Conic comet: transparent for most of the turn, ramping to full accent at its head.
    private var comet: some View {
        Circle()
            .inset(by: sweepWidth / 2)
            .stroke(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: SweepTokens.accent.opacity(0), location: 0.00),
                        .init(color: SweepTokens.accent.opacity(0), location: 0.42),
                        .init(color: SweepTokens.accent.opacity(0.18), location: 0.70),
                        .init(color: SweepTokens.accent.opacity(0.55), location: 0.88),
                        .init(color: SweepTokens.accent, location: 1.00),
                    ]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: sweepWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(rotationAngle))
            .scaleEffect(state == .complete ? 0.86 : 1)
            .opacity(state == .scanning ? 1 : 0)
    }

    /// Reduce Motion substitute: a dimmed, stationary accent ring during the scan.
    private var reducedIndicator: some View {
        Circle()
            .inset(by: sweepWidth / 2)
            .stroke(SweepTokens.accent.opacity(0.3), lineWidth: sweepWidth)
            .opacity(state == .scanning ? 1 : 0)
    }

    /// Draws itself clockwise from twelve o'clock when the scan lands. An angular gradient sweep
    /// (PLAN §5 volume-raise) rather than a flat stroke — still one hue family, just given some
    /// depth around the ring instead of reading as a single flat line.
    ///
    /// Completion choreography (PLAN §5, "Motion continuity"): the trim starts after
    /// `SweepMotion.decelerationDuration`, the same span `stopSpin(decelerate:)` gives the comet
    /// to coast to a stop, so the circle only starts closing once the turn has actually settled
    /// rather than closing underneath a comet still visibly spinning.
    private var settledRing: some View {
        Circle()
            .inset(by: sweepWidth / 2)
            .trim(from: 0, to: state == .complete ? 1 : 0)
            .stroke(SweepTokens.ringSweep, style: StrokeStyle(lineWidth: sweepWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .scaleEffect(pulseScale)
            .animation(
                reduceMotion ? SweepMotion.crossfade : SweepMotion.ringTrim.delay(SweepMotion.decelerationDuration),
                value: state
            )
    }

    private func syncTurning() {
        // Determinate arcs never turn — their motion is the fill growing, not a sweep.
        let shouldTurn = state == .scanning && !reduceMotion && animationsEnabled && !isDeterminate
        if shouldTurn {
            startSpin()
        } else {
            stopSpin(decelerate: state == .complete)
        }
    }

    /// One `sweepPeriod`-long linear leg per loop, each one bumping `rotationAngle` by exactly
    /// one full turn. Indistinguishable from the old `repeatForever` while it runs, but every leg
    /// leaves a real value behind for ``stopSpin(decelerate:)`` to ease out from.
    private func startSpin() {
        guard spinTask == nil else { return }
        spinTask = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.linear(duration: SweepMotion.sweepPeriod)) {
                    rotationAngle += 360
                }
                try? await Task.sleep(for: .seconds(SweepMotion.sweepPeriod))
            }
        }
    }

    /// PLAN §5, "Motion continuity": the turn decelerates to rest instead of snapping to 0.
    /// Coasts forward — never backward, which would read as the sweep reversing — to the next
    /// multiple of 360° on an ease-out curve, so it always comes to rest at the same orientation
    /// the settled ring draws from.
    private func stopSpin(decelerate: Bool) {
        spinTask?.cancel()
        spinTask = nil
        guard decelerate, !reduceMotion else { return }
        let remainder = rotationAngle.truncatingRemainder(dividingBy: 360)
        let toNextStop = remainder <= 0.01 ? 0 : (360 - remainder)
        guard toNextStop > 0 else { return }
        withAnimation(.easeOut(duration: SweepMotion.decelerationDuration)) {
            rotationAngle += toNextStop
        }
    }

    /// One completion pulse (PLAN §5 volume-raise): the settled ring breathes out and back once
    /// when the scan lands, layered on top of the trim-in rather than replacing it. Skipped
    /// entirely under Reduce Motion, same as every other kinetic flourish here.
    private func pulseOnCompletion() {
        guard state == .complete, !reduceMotion else { return }
        withAnimation(SweepMotion.completionPulse) { pulseScale = 1.05 }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(SweepMotion.completionPulse) { pulseScale = 1.0 }
        }
    }
}

extension ScanRing where Content == EmptyView {
    public init(state: ScanRingState, diameter: CGFloat = 240, progress: Double? = nil) {
        self.init(state: state, diameter: diameter, progress: progress) { EmptyView() }
    }
}

#Preview("Scan ring") {
    ScanRingDemo()
        .padding(SweepTokens.s6)
}

private struct ScanRingDemo: View {
    @State private var state: ScanRingState = .idle
    @State private var bytes: Int64 = 0

    var body: some View {
        VStack(spacing: SweepTokens.s5) {
            ScanRing(state: state, diameter: 240) {
                switch state {
                case .idle:
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.quaternary)
                case .scanning, .complete:
                    HeroByteCounter(byteCount: bytes, size: 54, caption: "12,904 items")
                }
            }
            Picker("", selection: $state) {
                Text("Idle").tag(ScanRingState.idle)
                Text("Scanning").tag(ScanRingState.scanning)
                Text("Complete").tag(ScanRingState.complete)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Button("Roll bytes") { bytes = Int64.random(in: 1_000_000...90_000_000_000) }
        }
    }
}
