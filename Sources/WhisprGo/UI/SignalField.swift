import SwiftUI

/// The menu's hero: a dot-matrix waveform that breathes at rest, follows the
/// live input level while recording, and scans while transcribing. Every
/// phase is blended through smoothed weights so state changes never jump.
struct SignalField: View {
    enum Phase: Equatable {
        case attention
        case idle
        case recording
        case transcribing
    }

    let phase: Phase
    let levelMeter: AudioLevelMeter
    var columns = 44
    var rows = 11

    @State private var dynamics = FieldDynamics()
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(
            minimumInterval: reduceMotion ? 1.0 / 20.0 : 1.0 / 60.0,
            paused: !isVisible
        )) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let rawLevel = phase == .recording ? Double(levelMeter.load()) : 0
                dynamics.advance(to: time, phase: phase, rawLevel: rawLevel)
                draw(in: &context, size: size, time: reduceMotion ? 0 : time)
            }
        }
        // The menu window is only hidden when closed, so stop the clock explicitly.
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let spacingX = size.width / CGFloat(columns)
        let spacingY = size.height / CGFloat(rows)
        let maxRadius = min(spacingX, spacingY) * 0.3
        let centerRow = Double(rows - 1) / 2
        let d = dynamics

        for column in 0..<columns {
            let x = Double(column) / Double(columns - 1) * 2 - 1
            let envelope = exp(-x * x * 2.4) * 0.86 + 0.14

            let idle = envelope * (
                0.52
                    + 0.2 * sin(time * 1.15 - x * 3.4)
                    + 0.1 * sin(time * 0.61 + x * 7.3)
            )
            let chatter = 0.62
                + 0.38 * sin(time * 8.7 + Double(column) * 0.93)
                * sin(time * 3.3 - Double(column) * 0.41)
            let recording = max(0.07, d.level * envelope * chatter)
            let sweep = sin(time * 2.1) * 0.92
            let scan = envelope * (0.1 + 0.62 * exp(-pow(x - sweep, 2) / 0.018))
            let flat = 0.05

            let rest = 1 - d.recording - d.transcribing
            let active = max(0, rest) * (idle * (1 - d.attention) + flat * d.attention)
                + recording * d.recording
                + scan * d.transcribing

            for row in 0..<rows {
                let distance = abs(Double(row) - centerRow) / centerRow
                let lit = smoothstep(active + 0.1, active - 0.06, distance)
                let radius = maxRadius * CGFloat(0.42 + 0.58 * lit)
                let opacity = 0.1 + 0.88 * lit * (1 - distance * 0.35)

                let point = CGPoint(
                    x: (CGFloat(column) + 0.5) * spacingX,
                    y: (CGFloat(row) + 0.5) * spacingY
                )
                let rect = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(.primary.opacity(opacity))
                )
            }
        }
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }
}

/// Frame-rate independent smoothing for the field's phase weights and level.
private final class FieldDynamics {
    var level = 0.0
    var recording = 0.0
    var transcribing = 0.0
    var attention = 0.0
    private var lastTime: Double?

    func advance(to time: Double, phase: SignalField.Phase, rawLevel: Double) {
        let elapsed = lastTime.map { min(1.0 / 12.0, max(0, time - $0)) } ?? 0
        lastTime = time
        guard elapsed > 0 else {
            snap(to: phase)
            return
        }

        let target = min(1, sqrt(max(0, rawLevel)) * 2.6)
        // Fast attack keeps speech immediate; the slower release avoids flicker.
        level = approach(level, target, rate: target > level ? 30 : 9, elapsed)
        recording = approach(recording, phase == .recording ? 1 : 0, rate: 7, elapsed)
        transcribing = approach(transcribing, phase == .transcribing ? 1 : 0, rate: 7, elapsed)
        attention = approach(attention, phase == .attention ? 1 : 0, rate: 5, elapsed)
    }

    private func snap(to phase: SignalField.Phase) {
        recording = phase == .recording ? 1 : 0
        transcribing = phase == .transcribing ? 1 : 0
        attention = phase == .attention ? 1 : 0
    }

    private func approach(_ value: Double, _ target: Double, rate: Double, _ elapsed: Double) -> Double {
        value + (target - value) * (1 - exp(-rate * elapsed))
    }
}
