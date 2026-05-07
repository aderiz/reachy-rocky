import SwiftUI
import RockyKit

/// Rocky's on-screen presence. A stylised front-facing head: rounded body,
/// two antennas, two eyes. Live-rotates based on actual head yaw/pitch from
/// the robot, antennas tilt with the antenna joints. The eyes change to
/// reflect Rocky's high-level state (idle / listening / thinking / speaking
/// / error).
struct RockyAvatar: View {
    let state: AppServices.RockyState
    let pose: RPYPose?
    let antennas: Antennas?
    var size: CGFloat = 140

    var body: some View {
        // When sleeping, force a slumped-forward pose regardless of the
        // last-reported live values (the daemon may still report 0).
        let isSleeping = state == .sleeping
        let yaw = pose?.yaw ?? 0
        let pitch = isSleeping ? 0.55 : (pose?.pitch ?? 0)
        let roll = pose?.roll ?? 0

        ZStack {
            // Soft halo behind the head reflects the current state colour.
            Circle()
                .fill(stateColor.opacity(0.10))
                .frame(width: size * 1.5, height: size * 1.5)
                .blur(radius: 24)

            // Antennas — tilt with antenna joint values (in radians).
            Antenna(side: .left,
                    angleRad: -(antennas?.left ?? 0) * 0.6 + roll * 0.4,
                    color: stateColor)
                .frame(width: size * 0.18, height: size * 0.7)
                .offset(x: -size * 0.30, y: -size * 0.40)
            Antenna(side: .right,
                    angleRad: -(antennas?.right ?? 0) * 0.6 + roll * 0.4,
                    color: stateColor)
                .frame(width: size * 0.18, height: size * 0.7)
                .offset(x: size * 0.30, y: -size * 0.40)

            // Head body — a rounded "egg" that rotates with head pose.
            HeadBody()
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.96, blue: 0.99),
                        Color(red: 0.86, green: 0.88, blue: 0.92),
                    ],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(width: size * 0.78, height: size * 0.92)
                .overlay(
                    HeadBody()
                        .stroke(stateColor.opacity(0.4), lineWidth: 1.5)
                )
                .rotationEffect(.radians(roll * 0.6))
                .offset(x: -CGFloat(yaw) * size * 0.10,
                        y: CGFloat(pitch) * size * 0.10)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            // Face — eyes + tiny LED reflecting state. Rendered on top of head.
            Face(state: state, color: stateColor)
                .frame(width: size * 0.55, height: size * 0.30)
                .offset(x: -CGFloat(yaw) * size * 0.10,
                        y: CGFloat(pitch) * size * 0.10 - size * 0.04)
        }
        .frame(width: size * 1.1, height: size * 1.05)
        .animation(.easeOut(duration: 0.18), value: yaw)
        .animation(.easeOut(duration: 0.18), value: pitch)
        .animation(.easeOut(duration: 0.18), value: roll)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: stateKey)
    }

    private var stateColor: Color {
        switch state {
        case .sleeping:   return .gray
        case .waking:     return .yellow
        case .idle:       return .gray
        case .listening:  return .green
        case .thinking:   return .orange
        case .speaking:   return .blue
        case .error:      return .red
        }
    }

    private var stateKey: String {
        switch state {
        case .sleeping: "sleeping"; case .waking: "waking"
        case .idle: "idle"; case .listening: "listening"
        case .thinking: "thinking"; case .speaking: "speaking"
        case .error: "error"
        }
    }
}

/// Egg-shaped silhouette tracing Rocky Mini's actual head outline.
private struct HeadBody: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        let topRadius = w * 0.5
        let bottomRadius = w * 0.42
        p.move(to: CGPoint(x: rect.midX, y: 0))
        // Top half (rounded)
        p.addQuadCurve(to: CGPoint(x: w, y: topRadius * 0.95),
                       control: CGPoint(x: w, y: 0))
        // Right side — slightly bowed
        p.addQuadCurve(to: CGPoint(x: w - bottomRadius * 0.05, y: h - bottomRadius * 0.4),
                       control: CGPoint(x: w * 1.03, y: h * 0.6))
        // Bottom curve
        p.addQuadCurve(to: CGPoint(x: bottomRadius * 0.05, y: h - bottomRadius * 0.4),
                       control: CGPoint(x: rect.midX, y: h * 1.05))
        // Left side
        p.addQuadCurve(to: CGPoint(x: 0, y: topRadius * 0.95),
                       control: CGPoint(x: -w * 0.03, y: h * 0.6))
        // Top-left back to start
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: 0),
                       control: CGPoint(x: 0, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct Antenna: View {
    enum Side { case left, right }
    let side: Side
    let angleRad: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let stemBase = CGPoint(x: geo.size.width / 2, y: geo.size.height)
            let stemTip = CGPoint(
                x: stemBase.x + sin(angleRad) * geo.size.height * 0.65,
                y: stemBase.y - cos(angleRad) * geo.size.height * 0.65
            )
            ZStack {
                Path { p in
                    p.move(to: stemBase)
                    p.addLine(to: stemTip)
                }
                .stroke(color.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))

                Circle()
                    .fill(color)
                    .frame(width: geo.size.width * 0.42, height: geo.size.width * 0.42)
                    .position(stemTip)
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: angleRad)
    }
}

private struct Face: View {
    let state: AppServices.RockyState
    let color: Color
    @State private var blink = false
    @State private var thinkingPhase: Double = 0
    @State private var speakingPhase: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let eyeR = h * 0.22

            ZStack {
                eye(at: CGPoint(x: w * 0.32, y: h * 0.4), radius: eyeR)
                eye(at: CGPoint(x: w * 0.68, y: h * 0.4), radius: eyeR)

                // Mouth: small line that animates per state.
                MouthShape(state: state, phase: speakingPhase)
                    .stroke(color.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: w * 0.45, height: h * 0.28)
                    .position(x: w * 0.5, y: h * 0.85)
            }
        }
        // Removed the previous .onAppear that kicked off two repeatForever
        // animations and an unbounded blink Task. Those animations drove
        // a 60+ Hz view-body re-evaluation app-wide for as long as the
        // app was running, which thrashed the SwiftUI/AppKit run loop
        // and stole keystrokes from every TextField in the window. The
        // avatar still moves (head/antennas track live pose via the
        // .animation(...value:) modifiers above) — it just no longer
        // runs continuous decorative animations.
    }

    @ViewBuilder
    private func eye(at point: CGPoint, radius: CGFloat) -> some View {
        // Eye is a vertically-squashed rounded rectangle (Reachy LCD-style).
        // Sleeping → fully closed (thin slit). Blink → momentarily closed.
        let isSleeping = (state == .sleeping)
        let height: CGFloat = isSleeping
            ? radius * 0.10
            : (blink ? radius * 0.15 : radius * 1.4)
        let width: CGFloat = radius * 1.4
        RoundedRectangle(cornerRadius: radius * 0.55, style: .continuous)
            .fill(isSleeping ? color.opacity(0.55) : color)
            .frame(width: width, height: height)
            .position(point)
            .shadow(color: color.opacity(isSleeping ? 0.0 : 0.6), radius: 4)
    }
}

/// Mouth changes shape per state (subtle but legible).
private struct MouthShape: Shape {
    let state: AppServices.RockyState
    let phase: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch state {
        case .sleeping:
            // No mouth shape when sleeping; render a tiny "z" off to the side.
            let z = rect.height * 0.5
            p.move(to: CGPoint(x: rect.maxX - z, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX - z, y: rect.minY + z))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + z))
        case .waking:
            // Slight smile, like just-awakened.
            p.move(to: CGPoint(x: rect.width * 0.15, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.width * 0.85, y: rect.midY),
                           control: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.5))
        case .idle:
            // Subtle, slightly-smiling line.
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.width, y: rect.midY),
                           control: CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.4))
        case .listening:
            // Straight, attentive.
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        case .thinking:
            // Dot-dot-dot.
            let r = rect.height * 0.18
            for i in 0..<3 {
                let x = CGFloat(i) * rect.width * 0.4 + rect.width * 0.1
                p.addEllipse(in: CGRect(x: x - r, y: rect.midY - r,
                                        width: r * 2, height: r * 2))
            }
        case .speaking:
            // Open-mouth amplitude bobs with phase.
            let amp = rect.height * (0.25 + 0.45 * phase)
            p.addRoundedRect(
                in: CGRect(x: rect.width * 0.2,
                           y: rect.midY - amp * 0.5,
                           width: rect.width * 0.6,
                           height: amp),
                cornerSize: CGSize(width: amp * 0.5, height: amp * 0.5)
            )
        case .error:
            // Flat, slightly frown-curved.
            p.move(to: CGPoint(x: 0, y: rect.midY + rect.height * 0.2))
            p.addQuadCurve(to: CGPoint(x: rect.width, y: rect.midY + rect.height * 0.2),
                           control: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.2))
        }
        return p
    }
}
