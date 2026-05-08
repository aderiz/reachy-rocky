import SwiftUI
import RockyKit

/// Inspector → Motion. Rocky's body angles, in numbers and a calm
/// horizontal bar per axis.
///
/// Replaced the hand-rolled crescent arc dials with centered fill
/// bars: each row shows a thin horizontal track with a tick at neutral
/// (zero) and a colored capsule that grows from the tick toward the
/// current value. The bar's length communicates "how far from neutral
/// relative to the safety limit"; the colour tells you which axis;
/// the trailing label gives the precise reading. Layout is the same
/// row pattern across head pose, body, and antennas — easier to scan
/// than three different visual styles.
///
/// Per `docs/concepts/cockpit-design.md` Inspector principles: leading
/// section labels in `.caption2.weight(.semibold).tracking(0.6)`, no
/// pills, only Health keeps them. Status pills replaced by a quiet
/// caption row in the header.
struct MotionCard: View {
    @Environment(AppServices.self) private var services

    /// Antenna angle range used for visualisation. SafetyLimits doesn't
    /// declare an antenna max yet (the daemon enforces its own); ~60°
    /// matches the existing twitch clamp in MacFaceTracker and reads
    /// well on the bar.
    private let antennaMaxRad: Double = .pi / 3   // 60°

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            section("Head pose") {
                AxisRow(label: "Yaw",
                        angleRad: services.lastRobotState?.headPose.yaw ?? 0,
                        maxRad: SafetyLimits.headYawMax,
                        tint: .accentColor)
                AxisRow(label: "Pitch",
                        angleRad: services.lastRobotState?.headPose.pitch ?? 0,
                        maxRad: SafetyLimits.headPitchMax,
                        tint: .indigo)
                AxisRow(label: "Roll",
                        angleRad: services.lastRobotState?.headPose.roll ?? 0,
                        maxRad: SafetyLimits.headRollMax,
                        tint: .teal)
            }
            section("Body") {
                AxisRow(label: "Yaw",
                        angleRad: services.lastRobotState?.bodyYaw ?? 0,
                        maxRad: SafetyLimits.bodyYawMax,
                        tint: .orange)
            }
            section("Antennas") {
                AxisRow(label: "Right",
                        angleRad: services.lastRobotState?
                                    .antennasPosition.right ?? 0,
                        maxRad: antennaMaxRad,
                        tint: .green)
                AxisRow(label: "Left",
                        angleRad: services.lastRobotState?
                                    .antennasPosition.left ?? 0,
                        maxRad: antennaMaxRad,
                        tint: .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Motion", systemImage: "figure.stand")
                .font(.headline)
            Spacer()
            HStack(spacing: 8) {
                if let mode = services.lastRobotState?.controlMode {
                    Label(mode.rawValue,
                          systemImage: mode == .enabled
                            ? "bolt.fill" : "pause.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(mode == .enabled
                                          ? AnyShapeStyle(.green)
                                          : AnyShapeStyle(.secondary))
                        .labelStyle(.titleAndIcon)
                }
                Text("\(services.stateUpdateCount.formatted()) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) { content() }
        }
    }
}

// MARK: - Axis row

/// One row per axis: label · centered bar (grows from neutral toward
/// the current value) · signed degrees · range. Reads cleanly down
/// to the inspector's 320pt minimum width.
private struct AxisRow: View {
    let label: String
    let angleRad: Double
    let maxRad: Double
    let tint: Color

    private var clamped: Double { max(-maxRad, min(maxRad, angleRad)) }
    /// −1 (full negative limit) ... +1 (full positive limit)
    private var normalized: Double { clamped / max(0.0001, maxRad) }
    private var displayDeg: Double { angleRad * 180.0 / .pi }
    private var rangeDeg: Int { Int((maxRad * 180.0 / .pi).rounded()) }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(.primary)

            CenteredFillBar(value: normalized, tint: tint)
                .frame(height: 12)
                .frame(maxWidth: .infinity)

            Text(String(format: "%+.1f°", displayDeg))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 60, alignment: .trailing)

            Text("±\(rangeDeg)°")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.2), value: normalized)
    }
}

/// Horizontal track with a tick at neutral and a coloured capsule that
/// grows from the tick toward the current value. Negative values fill
/// to the left, positive to the right. The fill width visualises
/// magnitude relative to the joint's safety limit (`abs(normalized)`),
/// so a bar that's near the edge means "near the limit" regardless
/// of whether the limit is 40° or 180°.
private struct CenteredFillBar: View {
    /// −1 ... +1
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let halfWidth = width / 2
            let clamped = max(-1, min(1, value))
            let fillWidth = halfWidth * abs(clamped)

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(.tertiary)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Centered fill: positive → right of the tick;
                // negative → left of the tick.
                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth, height: 4)
                    .offset(x: clamped >= 0 ? halfWidth : halfWidth - fillWidth)

                // Neutral tick
                Capsule()
                    .fill(.secondary)
                    .frame(width: 2, height: 10)
                    .offset(x: halfWidth - 1)
            }
        }
    }
}
