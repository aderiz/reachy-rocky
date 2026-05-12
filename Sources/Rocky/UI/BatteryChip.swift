import SwiftUI

/// Glass-capsule power chip for the portrait. Apple-style pill
/// battery glyph + an explicit percent/voltage readout — modelled on
/// the iOS status-bar battery indicator. The glyph fills left-to-right
/// based on charge tier; on DC the fill is solid with a charging-bolt
/// overlay because the rail voltage reflects the charger, not the
/// cell, and we can't honestly report state-of-charge while powered.
struct PowerChipOverlay: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let snap = services.latestBattery
        let visible = (snap?.reachable == true) && (snap?.present == true)
        if visible {
            BatteryChip(snapshot: snap)
                .transition(.opacity)
        }
    }
}

struct BatteryChip: View {
    let snapshot: BatteryService.Snapshot?

    var body: some View {
        HStack(spacing: 8) {
            BatteryGlyph(snapshot: snapshot)
                .frame(width: 42, height: 18)
            Text(readout)
                .font(.system(size: 15, weight: .semibold, design: .rounded)
                        .monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.10), lineWidth: 0.5)
        )
        .help(tooltip)
    }

    /// Always a percentage — matches iPhone status-bar behaviour
    /// (the bolt overlay indicates charging, the percent indicates
    /// state-of-charge). On DC the relay reports 100% because the
    /// rail voltage is above the LiFePO4 fully-charged threshold.
    private var readout: String {
        guard let s = snapshot else { return "—" }
        if let p = s.percent { return "\(p)%" }
        if let v = s.voltageV { return String(format: "%.1fV", v) }
        return "—"
    }

    var tint: Color {
        BatteryGlyph(snapshot: snapshot).fillColor
    }

    var tooltip: String {
        guard let s = snapshot else { return "Power — waiting for relay…" }
        if !s.reachable {
            return "Power — relay unreachable. Is rocky_media_relay running on the bot?"
        }
        if !s.present {
            return "Power — no signal. Bot can't report supply voltage."
        }
        var parts: [String] = []
        if let st = s.status { parts.append(st) }
        if let v = s.voltageV { parts.append(String(format: "%.2f V", v)) }
        if let p = s.percent { parts.append("≈\(p)%") }
        if s.source == "dynamixel:reg144" { parts.append("via motor reg 144") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Battery glyph (iOS-style horizontal pill with charge fill)

private struct BatteryGlyph: View {
    let snapshot: BatteryService.Snapshot?

    var body: some View {
        // Canvas gives deterministic absolute positioning so the
        // outline / fill / terminal nub stay aligned regardless of
        // SwiftUI's layout inference (the previous ZStack version
        // got the fill vertically centred *then* offset, breaking
        // alignment).
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            let strokeW: CGFloat = max(1.2, h * 0.085)
            let bodyW = w - 3                      // 1pt gap + 2.5pt nub
            let cornerR = h * 0.30

            // 1. Outline — stroked rounded pill, inset by half stroke
            //    so the line sits inside the bounding box.
            let outlineRect = CGRect(
                x: strokeW / 2, y: strokeW / 2,
                width: bodyW - strokeW, height: h - strokeW
            )
            ctx.stroke(
                Path(roundedRect: outlineRect, cornerRadius: cornerR - strokeW / 2),
                with: .color(.primary.opacity(0.6)),
                lineWidth: strokeW
            )

            // 2. Positive terminal nub on the right
            let nubH = h * 0.45
            let nubRect = CGRect(
                x: bodyW + 0.5, y: (h - nubH) / 2,
                width: 2.5, height: nubH
            )
            ctx.fill(
                Path(roundedRect: nubRect, cornerRadius: 0.8),
                with: .color(.primary.opacity(0.6))
            )

            // 3. Inner fill — left-aligned, proportional to charge
            if let frac = fillFraction {
                let inset = strokeW + 1.0
                let innerW = (bodyW - inset * 2) * frac
                let innerH = h - inset * 2
                let innerRect = CGRect(
                    x: inset, y: inset,
                    width: max(2, innerW), height: innerH
                )
                ctx.fill(
                    Path(roundedRect: innerRect,
                         cornerRadius: max(0, cornerR - inset)),
                    with: .color(fillColor)
                )
            }
        }
        .overlay {
            // 4. Charging bolt — only when on DC. Drawn as a SwiftUI
            //    overlay (not into the Canvas) so SF Symbol rendering
            //    stays vector-perfect at any size.
            if snapshot?.powerSource == "dc" {
                GeometryReader { geo in
                    Image(systemName: "bolt.fill")
                        .font(.system(size: geo.size.height * 0.72,
                                      weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.30), radius: 0.5)
                        .frame(width: geo.size.width - 3,
                               height: geo.size.height,
                               alignment: .center)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: fillFraction)
    }

    /// 0.0–1.0 fill, or nil when there's nothing to draw.
    var fillFraction: Double? {
        guard let s = snapshot, s.reachable, s.present else { return nil }
        // On DC the rail voltage is the charger output, not the
        // cell — we can't honestly state state-of-charge while
        // powered. Show a solid-full fill so the iconography reads
        // "powered" rather than "drained".
        if s.powerSource == "dc" { return 1.0 }
        if let p = s.percent { return max(0.0, min(1.0, Double(p) / 100.0)) }
        return nil
    }

    var fillColor: Color {
        guard let s = snapshot else { return .gray }
        if s.powerSource == "dc" { return .green }
        let pct = s.percent ?? 100
        if pct < 15 { return .red }
        if pct < 30 { return .yellow }
        return .green
    }
}
