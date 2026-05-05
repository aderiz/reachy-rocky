import SwiftUI
import Vision

struct VisionCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Vision", systemImage: "eye")
                    .font(.headline)
                Spacer()
                StatusPill(active: services.lastFaceDetection != nil,
                           label: services.lastFaceDetection != nil ? "tracking" : "no face")
            }

            HStack(alignment: .top, spacing: 16) {
                FaceCanvas(
                    detection: services.lastFaceDetection,
                    target: services.lastFaceTarget
                )
                .frame(width: 240, height: 135)

                VStack(alignment: .leading, spacing: 6) {
                    metric("yaw target", value: services.lastFaceTarget?.yawRad,
                           degrees: true)
                    metric("pitch target", value: services.lastFaceTarget?.pitchRad,
                           degrees: true)
                    Divider()
                    Text("\(services.faceTargetCount) target events · \(services.faceDetectionCount) detections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if services.lastFaceTarget?.decayActive == true {
                        Label("idle decay", systemImage: "leaf")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func metric(_ label: String, value: Double?, degrees: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(format(value, degrees: degrees))
                .font(.caption.monospacedDigit())
        }
    }

    private func format(_ v: Double?, degrees: Bool) -> String {
        guard let v else { return "—" }
        let display = degrees ? v * 180.0 / .pi : v
        return String(format: degrees ? "%+.1f°" : "%+.3f", display)
    }
}

private struct StatusPill: View {
    let active: Bool
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct FaceCanvas: View {
    let detection: Vision.FaceTrackerService.Detection?
    let target: Vision.FaceTrackerService.Target?

    var body: some View {
        Canvas { ctx, size in
            // Frame outline.
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.stroke(
                Path(roundedRect: frame, cornerRadius: 8),
                with: .color(.gray.opacity(0.5)),
                lineWidth: 1
            )

            if let det = detection {
                // Map normalized bbox → canvas coords.
                let scaleX = size.width / CGFloat(det.frameWidth)
                let scaleY = size.height / CGFloat(det.frameHeight)
                let r = CGRect(
                    x: det.bbox.origin.x * scaleX,
                    y: det.bbox.origin.y * scaleY,
                    width: det.bbox.width * scaleX,
                    height: det.bbox.height * scaleY
                )
                ctx.stroke(
                    Path(roundedRect: r, cornerRadius: 4),
                    with: .color(.green),
                    lineWidth: 2
                )
            }

            // Target arrow at the canvas center.
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let yaw = target?.yawRad ?? 0
            let pitch = target?.pitchRad ?? 0
            // Visual scale: ~1 rad = 60 px (for a tiny preview pane).
            let dx = -CGFloat(yaw) * 60
            let dy = CGFloat(pitch) * 60
            let tip = CGPoint(x: center.x + dx, y: center.y + dy)

            var path = Path()
            path.move(to: center)
            path.addLine(to: tip)
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
            ctx.fill(
                Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)),
                with: .color(.accentColor)
            )
        }
        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
