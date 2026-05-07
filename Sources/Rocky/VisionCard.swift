import SwiftUI
import Vision

/// VisionCard — what Rocky sees. Shows the (synthetic or real) face-tracker
/// preview with a face bbox overlay + the controller's commanded gaze
/// direction. Info row shows yaw/pitch + counters.
struct VisionCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Card {
            CardHeader("Vision", icon: "eye") {
                StatusPill(
                    text: services.lastFaceDetection != nil ? "tracking" : "idle",
                    tint: services.lastFaceDetection != nil ? .green : .secondary,
                    systemImage: services.lastFaceDetection != nil ? "viewfinder" : "circle"
                )
            }
        } content: {
            HStack(alignment: .top, spacing: 18) {
                FacePreview(
                    detection: services.lastFaceDetection,
                    target: services.lastFaceTarget
                )
                .frame(width: 360, height: 200)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "World target")
                        HStack(spacing: 14) {
                            metric("yaw",
                                   value: services.lastFaceTarget?.yawRad,
                                   degrees: true)
                            metric("pitch",
                                   value: services.lastFaceTarget?.pitchRad,
                                   degrees: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "Counters")
                        Text("\(services.faceTargetCount.formatted()) targets")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(services.faceDetectionCount.formatted()) detections")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if services.lastFaceTarget?.decayActive == true {
                        Label("Idle decay → home", systemImage: "house.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metric(_ label: String, value: Double?, degrees: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(format(value, degrees: degrees))
                .font(.body.monospacedDigit().weight(.medium))
        }
    }

    private func format(_ v: Double?, degrees: Bool) -> String {
        guard let v else { return "—" }
        let display = degrees ? v * 180.0 / .pi : v
        return String(format: degrees ? "%+.1f°" : "%+.3f", display)
    }
}

private struct FacePreview: View {
    let detection: Vision.FaceTrackerService.Detection?
    let target: Vision.FaceTrackerService.Target?

    var body: some View {
        Canvas { ctx, size in
            // Cinematic background gradient
            let bg = LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.07, blue: 0.10),
                    Color(red: 0.10, green: 0.12, blue: 0.16),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size),
                          cornerRadius: 12),
                     with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.06, green: 0.07, blue: 0.10),
                            Color(red: 0.10, green: 0.12, blue: 0.16),
                        ]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            _ = bg
            // Subtle horizon line
            var hpath = Path()
            hpath.move(to: CGPoint(x: 0, y: size.height / 2))
            hpath.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(hpath, with: .color(.white.opacity(0.07)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            var vpath = Path()
            vpath.move(to: CGPoint(x: size.width / 2, y: 0))
            vpath.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            ctx.stroke(vpath, with: .color(.white.opacity(0.07)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            // Detection bbox (if any)
            if let det = detection {
                let scaleX = size.width / CGFloat(det.frameWidth)
                let scaleY = size.height / CGFloat(det.frameHeight)
                let r = CGRect(
                    x: det.bbox.origin.x * scaleX,
                    y: det.bbox.origin.y * scaleY,
                    width: det.bbox.width * scaleX,
                    height: det.bbox.height * scaleY
                )
                // Soft fill + green frame
                ctx.fill(Path(roundedRect: r, cornerRadius: 8),
                         with: .color(.green.opacity(0.10)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 8),
                           with: .color(.green),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
                // Confidence label
                let confText = Text(String(format: "%.0f%%", det.confidence * 100))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundColor(.white)
                ctx.draw(confText,
                         at: CGPoint(x: r.minX + 6, y: r.minY + 10),
                         anchor: .leading)
            }

            // Target arrow (yaw, pitch) projected from frame center
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let yaw = target?.yawRad ?? 0
            let pitch = target?.pitchRad ?? 0
            let dx = -CGFloat(yaw) * size.width * 0.45
            let dy = CGFloat(pitch) * size.height * 0.45
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
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
