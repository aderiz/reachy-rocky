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
        HStack(spacing: 6) {
            BatteryGlyph(snapshot: snapshot)
                .frame(width: 26, height: 12)
            Text(readout)
                .font(.system(size: 12, weight: .semibold, design: .rounded)
                        .monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.08), lineWidth: 0.5)
        )
        .help(tooltip)
    }

    /// What sits to the right of the glyph.
    ///   - On DC: voltage, because percent isn't measurable while
    ///     the charger is regulating the rail. Voltage is the most
    ///     honest available number.
    ///   - On battery: percent, the iPhone-style "65%" readout.
    ///   - Otherwise: voltage if known, "—" as last resort.
    private var readout: String {
        guard let s = snapshot else { return "—" }
        if s.powerSource == "dc" {
            if let v = s.voltageV { return String(format: "%.1fV", v) }
            return "DC"
        }
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
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let bodyW = max(0, w - 3)            // 1 px gap + 2 px tip
            let cornerR = h * 0.32
            let strokeWidth = max(1.0, h * 0.10)

            ZStack(alignment: .leading) {
                // Outline
                RoundedRectangle(cornerRadius: cornerR, style: .continuous)
                    .stroke(.primary.opacity(0.55), lineWidth: strokeWidth)
                    .frame(width: bodyW, height: h)

                // Positive terminal nub on the right
                RoundedRectangle(cornerRadius: 0.6, style: .continuous)
                    .fill(.primary.opacity(0.55))
                    .frame(width: 2, height: h * 0.45)
                    .offset(x: bodyW + 1)

                // Inner fill — width proportional to charge
                if let frac = fillFraction {
                    let inset = strokeWidth + 1
                    let innerW = max(0, bodyW - inset * 2)
                    let innerH = max(0, h - inset * 2)
                    RoundedRectangle(cornerRadius: cornerR - inset,
                                     style: .continuous)
                        .fill(fillColor)
                        .frame(width: max(2, innerW * frac), height: innerH)
                        .offset(x: inset, y: inset)
                        .animation(.easeOut(duration: 0.25), value: frac)
                }

                // Charging bolt overlay (DC plugged in). Sits on top
                // of the fill, centred on the glyph.
                if snapshot?.powerSource == "dc" {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: h * 0.78,
                                      weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 0.6)
                        .frame(width: bodyW, height: h, alignment: .center)
                }
            }
        }
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
