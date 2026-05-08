import SwiftUI
import RockyKit

/// Inspector → Motion. Rocky's body angles as a macOS info panel.
///
/// The cockpit's 3D head is the visual motion display. This tab is the
/// data sheet next to it — numbers, factual, dense, scan-friendly.
/// Every row is a `LabeledContent` (the same control macOS uses in
/// System Settings, Get Info, etc.) so the values right-align under
/// each other and the eye reads down a column instead of bouncing
/// between gauge and label.
///
/// Per `docs/concepts/cockpit-design.md` Inspector principles: no
/// pills, only Health keeps them; section labels in
/// `.caption2.weight(.semibold).tracking(0.6)`; no card chrome (the
/// inspector tab is already the container); monospaced digits on
/// every angle so they don't jitter as values change.
struct MotionCard: View {
    @Environment(AppServices.self) private var services
    @State private var showLimits: Bool = false

    /// SafetyLimits doesn't currently declare an antenna max; the
    /// twitch clamp inside MacFaceTracker uses ~60°. Used only for the
    /// "Limits" reference section, not for visualisation.
    private let antennaLimitDeg: Int = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            section("Head pose") {
                row("Yaw",   services.lastRobotState?.headPose.yaw)
                row("Pitch", services.lastRobotState?.headPose.pitch)
                row("Roll",  services.lastRobotState?.headPose.roll)
            }
            section("Body") {
                row("Yaw", services.lastRobotState?.bodyYaw)
            }
            section("Antennas") {
                row("Right", services.lastRobotState?.antennasPosition.right)
                row("Left",  services.lastRobotState?.antennasPosition.left)
            }
            limitsSection
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

    // MARK: - Sections

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) { content() }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ angleRad: Double?) -> some View {
        LabeledContent(label) {
            Text(format(angleRad))
                .font(.body.monospacedDigit().weight(.medium))
                .foregroundStyle(angleRad == nil
                                  ? AnyShapeStyle(.tertiary)
                                  : AnyShapeStyle(.primary))
        }
    }

    private func format(_ angleRad: Double?) -> String {
        guard let angleRad else { return "—" }
        return String(format: "%+.1f°", angleRad * 180.0 / .pi)
    }

    // MARK: - Limits

    /// Collapsed by default — most of the time the user doesn't care
    /// what the safety ceiling is, only what the current value is.
    /// Open it when triaging "is Rocky near a limit?" and the numbers
    /// above don't tell the story.
    private var limitsSection: some View {
        DisclosureGroup(isExpanded: $showLimits) {
            VStack(spacing: 2) {
                LabeledContent("Head yaw") {
                    Text("±\(deg(SafetyLimits.headYawMax))°")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Head pitch") {
                    Text("±\(deg(SafetyLimits.headPitchMax))°")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Head roll") {
                    Text("±\(deg(SafetyLimits.headRollMax))°")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Body yaw") {
                    Text("±\(deg(SafetyLimits.bodyYawMax))°")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Antennas") {
                    Text("±\(antennaLimitDeg)°")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Yaw delta") {
                    Text("≤\(deg(SafetyLimits.yawDeltaMax))°")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Safety limits")
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
        }
    }

    private func deg(_ rad: Double) -> Int {
        Int((rad * 180.0 / .pi).rounded())
    }
}
