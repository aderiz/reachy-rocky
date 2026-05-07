import SwiftUI
import AppKit
import RockyVision

/// VisionCard — what Rocky sees through the actual robot camera. Live JPEG
/// frames stream in from the `robot-camera` sidecar; the face-tracker
/// sidecar's bbox + commanded gaze direction are overlaid on top.
struct VisionCard: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Card {
            CardHeader("Vision", icon: "eye") {
                if services.cameraFrameCount > 0 {
                    StatusPill(
                        text: "live · \(services.cameraFrameCount) frames",
                        tint: .green,
                        systemImage: "video.fill"
                    )
                }
                StatusPill(
                    text: trackingPillText,
                    tint: services.lastFaceDetection != nil ? .green : .secondary,
                    systemImage: services.lastFaceDetection != nil ? "viewfinder" : "circle"
                )
            }
        } content: {
            HStack(alignment: .top, spacing: 18) {
                FacePreview(
                    frame: services.lastCameraFrame,
                    detection: services.lastFaceDetection,
                    target: services.lastFaceTarget
                )
                .frame(width: 380, height: 214)

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
                        Text("\(services.cameraFrameCount.formatted()) camera frames")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if services.lastFaceTarget?.decayActive == true {
                        Label("Idle decay → home", systemImage: "house.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }

                    if services.lastCameraFrame == nil {
                        Label("Waiting for camera…", systemImage: "video.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var trackingPillText: String {
        guard let det = services.lastFaceDetection else { return "idle" }
        if let identity = det.identity { return "tracking · \(identity)" }
        return "tracking"
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
    let frame: RobotCameraService.Frame?
    let detection: RockyVision.FaceTrackerService.Detection?
    let target: RockyVision.FaceTrackerService.Target?

    var body: some View {
        ZStack {
            // Live camera image as the background, or a dark gradient if
            // no frame has arrived yet.
            if let frame, let nsImage = NSImage(data: frame.jpeg) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.07, blue: 0.10),
                        Color(red: 0.10, green: 0.12, blue: 0.16),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "video.slash")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.25))
            }

            // Detection bbox + target arrow on top of the image.
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
                        // Three label modes:
                        //   identified → "Alice 0.34"
                        //   in library but above threshold → "? Alice 0.92"
                        //   no library match → "73%" confidence fallback
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
