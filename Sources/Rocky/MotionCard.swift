import SwiftUI
import RockyKit

/// Inspector → Motion. A small live 3D head at the top, plus compact
/// per-axis rows underneath.
///
/// The cockpit's 3D head is the visual that ties everything in the app
/// to Rocky's actual body. Putting a smaller version here means the
/// inspector tab carries that same character — visual, alive, in
/// keeping with the rest of the app — instead of being a wall of text
/// that doesn't belong.
///
/// Each row beneath the head: label · centered fill bar · signed
/// degrees · limit. The bar magnitude visualises *how close to the
/// safety ceiling* the joint currently is, regardless of whether that
/// ceiling is ±40° or ±180°. The limit reads inline as a quiet
/// caption — no separate "safety limits" disclosure to hijack the
/// view.
struct MotionCard: View {
    @Environment(AppServices.self) private var services

    /// Antennas don't have a SafetyLimits constant; the twitch clamp
    /// inside MacFaceTracker uses ~60°. Used for both the bar's
    /// normalisation and the inline limit caption.
    private let antennaMaxRad: Double = .pi / 3   // 60°

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            preview
            headerStrip
            section("Head pose") {
                AxisRow(label: "Yaw",
                        angleRad: services.lastRobotState?.headPose.yaw,
                        maxRad: SafetyLimits.headYawMax,
                        tint: .accentColor)
                AxisRow(label: "Pitch",
                        angleRad: services.lastRobotState?.headPose.pitch,
                        maxRad: SafetyLimits.headPitchMax,
                        tint: .indigo)
                AxisRow(label: "Roll",
                        angleRad: services.lastRobotState?.headPose.roll,
                        maxRad: SafetyLimits.headRollMax,
                        tint: .teal)
            }
            section("Body") {
                AxisRow(label: "Yaw",
                        angleRad: services.lastRobotState?.bodyYaw,
                        maxRad: SafetyLimits.bodyYawMax,
                        tint: .orange)
            }
            section("Antennas") {
                AxisRow(label: "Right",
                        angleRad: services.lastRobotState?
                                    .antennasPosition.right,
                        maxRad: antennaMaxRad,
                        tint: .green)
                AxisRow(label: "Left",
                        angleRad: services.lastRobotState?
                                    .antennasPosition.left,
                        maxRad: antennaMaxRad,
                        tint: .green)
            }
            stewartDebugSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Diagnostic — surface the daemon's reported Stewart motor
    /// angles + passive joints. The avatar's elevation depends on
    /// these arriving from the daemon. nil means we drop back to
    /// URDF rest (which on this URDF is the fully retracted "ship"
    /// pose, not the elevated home pose).
    private var stewartDebugSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEWART (DAEMON)")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            if let motors = services.lastRobotState?.headJoints {
                Text("head_joints: " + motors.map {
                    String(format: "%+.2f", $0)
                }.joined(separator: " "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("head_joints: nil")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let passive = services.lastRobotState?.passiveJoints {
                Text("passive_joints: \(passive.count) values")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            } else {
                Text("passive_joints: nil")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ReachyMiniAvatar(
            state: services.rockyState,
            pose: services.lastRobotState?.headPose,
            antennas: services.lastRobotState?.antennasPosition,
            bodyYaw: services.lastRobotState?.bodyYaw,
            headJoints: services.lastRobotState?.headJoints,
            passiveJoints: services.lastRobotState?.passiveJoints
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Header strip

    private var headerStrip: some View {
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

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) { content() }
        }
    }
}

// MARK: - Axis row

/// One row per axis. Label · centered fill bar · value · limit, all
/// in a single line that fits the inspector's 320pt minimum width.
private struct AxisRow: View {
    let label: String
    let angleRad: Double?
    let maxRad: Double
    let tint: Color

    private var clamped: Double {
        let v = angleRad ?? 0
        return max(-maxRad, min(maxRad, v))
    }
    private var normalized: Double {
        clamped / max(0.0001, maxRad)
    }
    private var displayDeg: Double {
        (angleRad ?? 0) * 180.0 / .pi
    }
    private var rangeDeg: Int {
        Int((maxRad * 180.0 / .pi).rounded())
    }
    private var hasValue: Bool { angleRad != nil }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 50, alignment: .leading)
                .foregroundStyle(.primary)

            CenteredFillBar(value: hasValue ? normalized : 0, tint: tint)
                .frame(height: 10)
                .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Text(hasValue
                     ? String(format: "%+.1f°", displayDeg)
                     : "—")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(hasValue
                                      ? AnyShapeStyle(.primary)
                                      : AnyShapeStyle(.tertiary))
                Text("/\u{00A0}±\(rangeDeg)°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 110, alignment: .trailing)
        }
        .animation(.easeOut(duration: 0.2), value: normalized)
    }
}

/// Centered horizontal fill: a thin track with a tick at zero, and a
/// coloured capsule that grows from the tick toward the current value.
/// Negative values fill left, positive fill right. The capsule's
/// length is `|value| / safety_limit`, so a bar near the edge means
/// "near the limit" regardless of whether the limit is ±40° or ±180°.
private struct CenteredFillBar: View {
    let value: Double   // -1 ... +1
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let halfWidth = width / 2
            let v = max(-1, min(1, value))
            let fillWidth = halfWidth * abs(v)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary)
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                Capsule()
                    .fill(tint)
                    .frame(width: fillWidth, height: 4)
                    .offset(x: v >= 0 ? halfWidth : halfWidth - fillWidth)
                Capsule()
                    .fill(.secondary)
                    .frame(width: 2, height: 8)
                    .offset(x: halfWidth - 1)
            }
        }
    }
}
