import SwiftUI
import RockyKit

struct MotionCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Motion", systemImage: "figure.stand")
                    .font(.headline)
                Spacer()
                if let mode = services.lastRobotState?.controlMode {
                    Pill(text: "motors: \(mode.rawValue)",
                         tint: mode == .enabled ? .green : .gray)
                }
                Pill(text: "\(services.stateUpdateCount) frames", tint: .secondary)
            }

            HStack(alignment: .top, spacing: 16) {
                HeadGauges(state: services.lastRobotState)
                    .frame(width: 220)
                AntennasPanel(state: services.lastRobotState)
                    .frame(width: 200)
                BodyYawPanel(state: services.lastRobotState)
                    .frame(width: 160)
                Spacer()
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct HeadGauges: View {
    let state: RobotState?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Head pose").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            row("yaw",   value: state?.headPose.yaw,   limit: SafetyLimits.headYawMax)
            row("pitch", value: state?.headPose.pitch, limit: SafetyLimits.headPitchMax)
            row("roll",  value: state?.headPose.roll,  limit: SafetyLimits.headRollMax)
        }
    }

    @ViewBuilder
    private func row(_ label: String, value: Double?, limit: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.gray.opacity(0.2)).frame(height: 8)
                if let v = value {
                    let normalized = max(-1, min(1, v / limit))
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: abs(normalized) * (geo.size.width / 2),
                                   height: 8)
                            .offset(x: normalized < 0
                                    ? (1 + normalized) * (geo.size.width / 2)
                                    : geo.size.width / 2)
                    }
                    .frame(height: 8)
                }
            }
            Text(format(value)).font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.1f°", v * 180.0 / .pi)
    }
}

private struct AntennasPanel: View {
    let state: RobotState?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Antennas").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                bar("R", angleRad: state?.antennasPosition.right)
                bar("L", angleRad: state?.antennasPosition.left)
            }
            .frame(height: 80)
        }
    }

    @ViewBuilder
    private func bar(_ label: String, angleRad: Double?) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottom) {
                Capsule().fill(.gray.opacity(0.2)).frame(width: 14, height: 60)
                if let v = angleRad {
                    // Map ~ ±π to a 0..60 bar height visually.
                    let normalized = max(0, min(1, (v + .pi) / (2 * .pi)))
                    Capsule().fill(Color.accentColor)
                        .frame(width: 14, height: max(2, normalized * 60))
                }
            }
            Text(angleRad.map { String(format: "%+.0f°", $0 * 180.0 / .pi) } ?? "—")
                .font(.caption2.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct BodyYawPanel: View {
    let state: RobotState?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Body yaw").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            BodyYawArc(angleRad: state?.bodyYaw ?? 0)
                .frame(height: 80)
            Text(state.map { String(format: "%+.1f°", $0.bodyYaw * 180.0 / .pi) } ?? "—")
                .font(.caption.monospacedDigit())
        }
    }
}

private struct BodyYawArc: View {
    let angleRad: Double
    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2 - 4
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 4)

            Canvas { ctx, _ in
                // Track
                var track = Path()
                track.addArc(
                    center: center, radius: r,
                    startAngle: .degrees(180),
                    endAngle: .degrees(360),
                    clockwise: false
                )
                ctx.stroke(track, with: .color(.gray.opacity(0.3)), lineWidth: 4)

                // Indicator at the current yaw (negate for screen orientation:
                // +yaw = robot turning LEFT -> needle moves to viewer's left).
                let limit = SafetyLimits.bodyYawMax
                let clamped = max(-limit, min(limit, angleRad))
                let normalized = clamped / limit  // -1...+1
                let angle = .pi - normalized * (.pi / 2)
                let tip = CGPoint(
                    x: center.x + r * cos(angle),
                    y: center.y - r * sin(angle)
                )
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: tip)
                ctx.stroke(needle, with: .color(.accentColor), lineWidth: 2)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)),
                    with: .color(.accentColor)
                )
            }
        }
    }
}

private struct Pill: View {
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
