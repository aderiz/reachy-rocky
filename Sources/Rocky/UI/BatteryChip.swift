import SwiftUI

/// Glass-styled power chip for overlay on the portrait avatar.
/// Mirrors `BatteryChip` (same data + tooltip) but renders in a
/// rounded-rectangle material capsule so it sits cleanly on the
/// portrait gradient. Hides itself when there's no signal so the
/// avatar isn't permanently bracketed by a grey placeholder.
struct PowerChipOverlay: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let snap = services.latestBattery
        let visible = (snap?.reachable == true) && (snap?.present == true)
        if visible {
            BatteryChip(snapshot: snap)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial,
                            in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.08), lineWidth: 0.5)
                )
                .help(BatteryChip(snapshot: snap).tooltip)
                .transition(.opacity)
        }
    }
}

/// Compact toolbar chip that shows Rocky's battery state.
///
/// Tier:
///   - `< 15%` red, "Charging" trumps low so a charging bot reads green.
///   - `< 30%` orange.
///   - else green.
///
/// Variants:
///   - `nil` snapshot → "—" placeholder (haven't polled yet).
///   - `reachable: false` → unreachable glyph + tooltip.
///   - `present: false` → "BMS off" glyph + tooltip.
///
/// Wired into the toolbar as a `Label`; macOS renders it as a glyph
/// chip in the toolbar group.
struct BatteryChip: View {
    let snapshot: BatteryService.Snapshot?

    var body: some View {
        Label(label, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.callout.monospacedDigit())
            .foregroundStyle(tint)
            .help(tooltip)
    }

    private var label: String {
        guard let s = snapshot else { return "—" }
        if !s.reachable { return "—" }
        if !s.present { return "—" }
        // On DC the percent is unknown (the rail shows the charger
        // voltage, not the cell voltage). Show "DC" so the user knows
        // it's a binary state, not a low-battery warning.
        if s.powerSource == "dc" {
            if let v = s.voltageV { return String(format: "DC %.1fV", v) }
            return "DC"
        }
        if let p = s.percent { return "\(p)%" }
        if let v = s.voltageV { return String(format: "%.1fV", v) }
        return "—"
    }

    private var symbol: String {
        guard let s = snapshot else { return "battery.0percent" }
        if !s.reachable { return "battery.0percent" }
        if !s.present { return "battery.0percent" }
        // DC plugged in: power plug icon — distinct from "battery
        // charging" because here we can't see actual SOC during
        // charge (the rail is at charger voltage).
        if s.powerSource == "dc" {
            return "powerplug.fill"
        }
        let pct = s.percent ?? 0
        // SF Symbols ladder: 0/25/50/75/100. Pick the highest tier
        // whose threshold the battery still meets.
        if pct >= 88 { return "battery.100percent" }
        if pct >= 63 { return "battery.75percent" }
        if pct >= 38 { return "battery.50percent" }
        if pct >= 13 { return "battery.25percent" }
        return "battery.0percent"
    }

    var tint: Color {
        guard let s = snapshot else { return .secondary }
        if !s.reachable || !s.present { return .secondary }
        if s.powerSource == "dc" { return .blue }
        let pct = s.percent ?? 100
        if pct < 15 { return .red }
        if pct < 30 { return .orange }
        return .green
    }

    var tooltip: String {
        guard let s = snapshot else { return "Battery — waiting for relay…" }
        if !s.reachable {
            return "Battery — relay unreachable. Is `rocky_media_relay` running on the bot?"
        }
        if !s.present {
            return "Battery — bot kernel doesn't expose the BMS, and the motors aren't reporting voltage. No data available."
        }
        var parts: [String] = []
        if let st = s.status { parts.append(st) }
        if let v = s.voltageV { parts.append(String(format: "%.2f V", v)) }
        if let p = s.percent { parts.append("\(p)%") }
        if let t = s.temperatureC { parts.append(String(format: "%.0f°C", t)) }
        if s.source == "dynamixel:reg144" {
            parts.append("via motors")
        }
        return parts.joined(separator: " · ")
    }
}
