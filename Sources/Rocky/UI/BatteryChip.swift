import SwiftUI

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
        if let p = s.percent { return "\(p)%" }
        if let v = s.voltageV { return String(format: "%.1fV", v) }
        return "—"
    }

    private var symbol: String {
        guard let s = snapshot else { return "battery.0percent" }
        if !s.reachable { return "battery.0percent" }
        if !s.present { return "battery.0percent" }
        let pct = s.percent ?? 0
        let bolt = (s.charging == true) ? ".bolt" : ""
        // SF Symbols ladder: 0/25/50/75/100. Pick the highest tier
        // whose threshold the battery still meets.
        let base: String
        if pct >= 88 { base = "battery.100" }
        else if pct >= 63 { base = "battery.75" }
        else if pct >= 38 { base = "battery.50" }
        else if pct >= 13 { base = "battery.25" }
        else { base = "battery.0" }
        return "\(base)percent\(bolt)"
    }

    var tint: Color {
        guard let s = snapshot else { return .secondary }
        if !s.reachable || !s.present { return .secondary }
        if s.charging == true { return .green }
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
            return "Battery — bot kernel doesn't expose the BMS. No charge data available from this image."
        }
        var parts: [String] = []
        if let p = s.percent { parts.append("\(p)%") }
        if let st = s.status { parts.append(st.lowercased()) }
        if let v = s.voltageV { parts.append(String(format: "%.2f V", v)) }
        if let a = s.currentA { parts.append(String(format: "%.2f A", a)) }
        if let t = s.temperatureC { parts.append(String(format: "%.0f°C", t)) }
        return "Battery — " + parts.joined(separator: " · ")
    }
}
