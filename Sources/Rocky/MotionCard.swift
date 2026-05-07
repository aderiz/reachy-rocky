import SwiftUI
import RockyKit

/// MotionCard — concise, dial-driven readout of how Rocky's body is moving.
/// Hero already shows the head/antennas as a character; this card tells you
/// the numbers + body yaw arc, plus motor-mode and frame counter as compact
/// pills. Information density is intentionally low.
struct MotionCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Card {
            CardHeader("Motion", icon: "figure.stand") {
                if let mode = services.lastRobotState?.controlMode {
                    StatusPill(
                        text: "motors: \(mode.rawValue)",
                        tint: mode == .enabled ? .green : .gray,
                        systemImage: mode == .enabled ? "bolt.fill" : "pause.circle"
                    )
                }
                StatusPill(text: "\(services.stateUpdateCount) frames",
                           tint: .secondary)
            }
        } content: {
            HStack(alignment: .center, spacing: 28) {
                AngleDial(label: "yaw",
                          angleRad: services.lastRobotState?.headPose.yaw ?? 0,
                          maxRad: SafetyLimits.headYawMax,
                          tint: .accentColor)
                AngleDial(label: "pitch",
                          angleRad: services.lastRobotState?.headPose.pitch ?? 0,
                          maxRad: SafetyLimits.headPitchMax,
                          tint: .indigo)
                AngleDial(label: "roll",
                          angleRad: services.lastRobotState?.headPose.roll ?? 0,
                          maxRad: SafetyLimits.headRollMax,
                          tint: .teal)

                Divider().frame(height: 80)

                AngleDial(label: "body",
                          angleRad: services.lastRobotState?.bodyYaw ?? 0,
                          maxRad: SafetyLimits.bodyYawMax,
                          tint: .orange)

                Divider().frame(height: 80)

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Antennas")
                    HStack(spacing: 14) {
                        AntennaTick(label: "R",
                                    angleRad: services.lastRobotState?.antennasPosition.right ?? 0)
                        AntennaTick(label: "L",
                                    angleRad: services.lastRobotState?.antennasPosition.left ?? 0)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Circular gauge with a needle. Always shows the numeric value below.
private struct AngleDial: View {
    let label: String
    let angleRad: Double
    let maxRad: Double
    let tint: Color

    private var clamped: Double { max(-maxRad, min(maxRad, angleRad)) }
    private var normalized: Double { clamped / max(0.0001, maxRad) }
    private var displayDeg: Double { angleRad * 180.0 / .pi }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .trim(from: 0.625, to: 0.875)
                    .stroke(.gray.opacity(0.18),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(180))
                Circle()
                    .trim(from: 0.625, to: 0.625 + 0.25 * abs(normalized))
                    .stroke(tint,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(180 + (normalized < 0 ? 0 : -90 * normalized)))

                Text(String(format: "%+.1f°", displayDeg))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .offset(y: 4)
            }
            .frame(width: 78, height: 60)
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.2), value: normalized)
    }
}

private struct AntennaTick: View {
    let label: String
    let angleRad: Double

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Capsule().fill(.gray.opacity(0.15))
                    .frame(width: 4, height: 30)
                Capsule().fill(.green.opacity(0.7))
                    .frame(width: 4, height: 30)
                    .rotationEffect(.radians(angleRad))
            }
            .frame(width: 30, height: 36)
            Text(String(format: "%+.0f°", angleRad * 180.0 / .pi))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
