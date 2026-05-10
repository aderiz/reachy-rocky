import SwiftUI
import AppKit
import RockyVision
import Perception

/// Inspector → Vision. Live JPEG from the robot camera + bbox overlay
/// + world-target arrow + counters and identity readout.
///
/// Reflowed for the inspector column (320–520pt wide). Per
/// `docs/concepts/cockpit-design.md` §3.4 and the Inspector tab
/// principles:
///   - the JPEG frame uses `.aspectRatio(16/9, contentMode: .fit)` so
///     it grows with the column instead of overflowing at 320pt;
///   - the world target is two `LabeledContent` rows (Motion already
///     owns the dial style; redundant inline dials here are noise);
///   - counters become a single line of `.caption.monospacedDigit()`
///     text instead of three separate StatusPill rows;
///   - the identity label hangs under the camera frame so it reads
///     as "what Rocky sees" rather than as part of the metadata.
struct VisionCard: View {
    @Environment(AppServices.self) private var services
    @State private var showOverlays: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            preview
            identityLine
            section("World target") {
                LabeledContent("Yaw") {
                    Text(format(services.lastFaceTarget?.yawRad, degrees: true))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(services.lastFaceTarget == nil
                                          ? AnyShapeStyle(.tertiary)
                                          : AnyShapeStyle(.primary))
                }
                LabeledContent("Pitch") {
                    Text(format(services.lastFaceTarget?.pitchRad, degrees: true))
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(services.lastFaceTarget == nil
                                          ? AnyShapeStyle(.tertiary)
                                          : AnyShapeStyle(.primary))
                }
                if services.lastFaceTarget?.decayActive == true {
                    Label("Idle decay → home", systemImage: "house.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            section("Counters") {
                Text(countersLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Vision", systemImage: "eye")
                .font(.headline)
            Spacer()
            Toggle(isOn: $showOverlays) {
                Text("Overlays")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Draw the face-detection bbox and target arrow on the camera frame.")
        }
    }

    // MARK: - Preview

    private var preview: some View {
        FacePreview(
            frame: services.lastCameraFrame,
            detection: showOverlays ? services.lastFaceDetection : nil,
            target: showOverlays ? services.lastFaceTarget : nil
        )
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var identityLine: some View {
        HStack(spacing: 8) {
            Image(systemName: identityIcon)
                .foregroundStyle(identityTint)
                .frame(width: 16)
            Text(identityText)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var identityText: String {
        guard let det = services.lastFaceDetection else {
            return services.lastCameraFrame == nil
                ? "Camera not connected."
                : "No face in view."
        }
        if let id = det.identity, let d = det.identityDistance {
            return String(format: "%@ · distance %.2f", id, d)
        }
        if let name = det.closestName, let d = det.closestDistance {
            return String(format: "Closest match: %@ · %.2f (above threshold)", name, d)
        }
        return String(format: "Unknown face · confidence %.0f%%", det.confidence * 100)
    }

    private var identityIcon: String {
        guard let det = services.lastFaceDetection else { return "video.slash" }
        return det.identity != nil ? "person.fill.checkmark"
                                    : "person.crop.circle.fill.badge.questionmark"
    }

    private var identityTint: Color {
        guard let det = services.lastFaceDetection else { return .secondary }
        return det.identity != nil ? .accentColor : .secondary
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
            content()
        }
    }

    private var countersLine: String {
        let frames = services.cameraFrameCount.formatted()
        let detections = services.faceDetectionCount.formatted()
        let targets = services.faceTargetCount.formatted()
        return "\(frames) frames · \(detections) detections · \(targets) targets"
    }

    // MARK: - Helpers

    private func format(_ v: Double?, degrees: Bool) -> String {
        guard let v else { return "—" }
        let display = degrees ? v * 180.0 / .pi : v
        return String(format: degrees ? "%+.1f°" : "%+.3f", display)
    }
}

// MARK: - Face preview

/// JPEG with bbox + target arrow overlays. Now responsive: the parent
/// dictates size via aspect-ratio; we just fill it. Background uses a
/// system material instead of a hand-rolled gradient so light/dark
/// adapt automatically.
private struct FacePreview: View {
    let frame: RobotCameraService.Frame?
    let detection: MacFaceTracker.Detection?
    let target: FaceTargetSnapshot?

    var body: some View {
        ZStack {
            if let frame, let nsImage = NSImage(data: frame.jpeg) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.regularMaterial)
                Image(systemName: "video.slash")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
            Canvas { ctx, size in
                if let det = detection {
                    let scaleX = size.width / CGFloat(det.frameWidth)
                    let scaleY = size.height / CGFloat(det.frameHeight)
                    let r = CGRect(
                        x: det.bbox.origin.x * scaleX,
                        y: det.bbox.origin.y * scaleY,
                        width: det.bbox.width * scaleX,
                        height: det.bbox.height * scaleY
                    )
                    let strokeColor: Color = det.identity != nil ? .accentColor : .green
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 8),
                               with: .color(strokeColor),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    let labelString: String
                    if let identity = det.identity {
                        if let d = det.identityDistance {
                            labelString = String(format: "%@ %.2f", identity, d)
                        } else {
                            labelString = identity
                        }
                    } else if let name = det.closestName, let d = det.closestDistance {
                        labelString = String(format: "? %@ %.2f", name, d)
                    } else {
                        labelString = String(format: "%.0f%%", det.confidence * 100)
                    }
                    let label = Text(labelString)
                        .font(.caption.monospacedDigit().bold())
                        .foregroundColor(.white)
                    ctx.draw(label,
                             at: CGPoint(x: r.minX + 6, y: r.minY + 10),
                             anchor: .leading)
                }
                if let target {
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let dx = -CGFloat(target.yawRad) * size.width * 0.45
                    let dy = CGFloat(target.pitchRad) * size.height * 0.45
                    let tip = CGPoint(x: center.x + dx, y: center.y + dy)
                    var arrow = Path()
                    arrow.move(to: center)
                    arrow.addLine(to: tip)
                    ctx.stroke(arrow, with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: tip.x - 5, y: tip.y - 5,
                                               width: 10, height: 10)),
                        with: .color(.accentColor)
                    )
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3,
                                               width: 6, height: 6)),
                        with: .color(.white.opacity(0.8))
                    )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.tertiary, lineWidth: 1)
        )
    }
}
