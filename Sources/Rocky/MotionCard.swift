import SwiftUI
import RockyKit

/// Motion — Rocky's body angles in numbers, for the Inspector's
/// Motion tab.
///
/// This used to be a wide horizontal card sized for the dashboard; now
/// it lives inside the inspector at ~360pt and overflowed. Per
/// `docs/concepts/cockpit-design.md` §3.4, inspector tabs are a
/// scrollable column — so the layout flips to vertical sections (Head /
/// Body / Antennas) with the dial on the left of each row and the
/// label + signed degrees on the right.
///
/// The Card chrome is gone — the Inspector tab is already the
/// container. Status pills stay (motors mode, frame counter) because
/// they're meaningful diagnostics here even though we removed pills
/// from the cockpit stage.
struct MotionCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            section("Head pose") {
                AngleRow(label: "Yaw",
                         angleRad: services.lastRobotState?.headPose.yaw ?? 0,
                         maxRad: SafetyLimits.headYawMax,
                         tint: .accentColor)
                AngleRow(label: "Pitch",
                         angleRad: services.lastRobotState?.headPose.pitch ?? 0,
                         maxRad: SafetyLimits.headPitchMax,
                         tint: .indigo)
                AngleRow(label: "Roll",
                         angleRad: services.lastRobotState?.headPose.roll ?? 0,
                         maxRad: SafetyLimits.headRollMax,
                         tint: .teal)
            }
            section("Body") {
                AngleRow(label: "Yaw",
                         angleRad: services.lastRobotState?.bodyYaw ?? 0,
                         maxRad: SafetyLimits.bodyYawMax,
                         tint: .orange)
            }
            section("Antennas") {
                HStack(spacing: 18) {
                    AntennaRow(label: "R",
                               angleRad: services.lastRobotState?
                                  .antennasPosition.right ?? 0)
                    AntennaRow(label: "L",
                               angleRad: services.lastRobotState?
                                  .antennasPosition.left ?? 0)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Motion", systemImage: "figure.stand")
                .font(.headline)
            Spacer()
            HStack(spacing: 6) {
                if let mode = services.lastRobotState?.controlMode {
                    StatusPill(
                        text: "motors: \(mode.rawValue)",
                        tint: mode == .enabled ? .green : .gray,
                        systemImage: mode == .enabled
                            ? "bolt.fill" : "pause.circle"
                    )
                }
                StatusPill(text: "\(services.stateUpdateCount) frames",
                           tint: .secondary)
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
            content()
        }
    }
}

// MARK: - Angle row

/// Dial on the left, label + signed degrees on the right. Wraps
/// gracefully — width drops below ~200pt without truncating.
private struct AngleRow: View {
    let label: String
    let angleRad: Double
    let maxRad: Double
    let tint: Color

    private var clamped: Double { max(-maxRad, min(maxRad, angleRad)) }
    private var normalized: Double { clamped / max(0.0001, maxRad) }
    private var displayDeg: Double { angleRad * 180.0 / .pi }

    var body: some View {
        HStack(spacing: 14) {
            dial
                .frame(width: 64, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout.weight(.medium))
                Text(String(format: "%+.1f°", displayDeg))
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
            Text(rangeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .animation(.easeOut(duration: 0.2), value: normalized)
    }

    private var rangeLabel: String {
        let lim = maxRad * 180.0 / .pi
        return String(format: "±%.0f°", lim)
    }

    private var dial: some View {
        ZStack {
            Circle()
                .trim(from: 0.625, to: 0.875)
                .stroke(.tertiary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(180))
            Circle()
                .trim(from: 0.625, to: 0.625 + 0.25 * abs(normalized))
                .stroke(tint,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(180 + (normalized < 0 ? 0 : -90 * normalized)))
        }
    }
}

// MARK: - Antenna row

/// Vertical capsule that swings with the antenna's commanded angle.
/// Compact enough that two side-by-side fit a 320pt inspector column.
private struct AntennaRow: View {
    let label: String
    let angleRad: Double

    private var displayDeg: Double { angleRad * 180.0 / .pi }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Capsule()
                    .fill(.tertiary.opacity(0.4))
                    .frame(width: 4, height: 32)
                Capsule()
                    .fill(.green.opacity(0.8))
                    .frame(width: 4, height: 32)
                    .rotationEffect(.radians(angleRad))
            }
            .frame(width: 36, height: 40)
            Text(String(format: "%+.0f°", displayDeg))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .animation(.easeOut(duration: 0.2), value: angleRad)
    }
}
