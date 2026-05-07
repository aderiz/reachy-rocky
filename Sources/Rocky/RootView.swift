import SwiftUI
import RockyKit

/// The single window. Per `docs/concepts/cockpit-design.md` §3:
///
///   - The detail is the cockpit (currently the prototype centre column;
///     Wave 3 builds the new portrait + conversation stage).
///   - A real macOS `.toolbar` carries the global actions (Wake/Sleep,
///     Mic, Voice, Health glance, Inspector toggle).
///   - A trailing `.inspector` holds every diagnostic surface that used
///     to be a sidebar peer (Status, Logs, Memory, Motion, Vision, Raw).
///   - There is no sidebar — the cockpit is the only content the window
///     ever shows.
///
/// Settings lives in a separate `Settings { ... }` scene (see RockyApp);
/// ⌘, opens it.
struct RootView: View {
    @Environment(AppServices.self) private var services
    @State private var inspectorPresented: Bool = false

    var body: some View {
        CockpitView()
            .navigationTitle("Rocky")
            .toolbar { toolbarContent }
            .inspector(isPresented: $inspectorPresented) {
                InspectorView()
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 520)
            }
            .overlay {
                // First-run overlay — shows when the user has never
                // completed (or explicitly skipped) the introductory
                // flow. The overlay sits on top of the live cockpit
                // (rather than blocking it) so the avatar's animation
                // is visible behind the dim, giving a sense that
                // Rocky is *there* during onboarding.
                if !services.settings.firstRunCompleted {
                    FirstRunOverlay()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25),
                       value: services.settings.firstRunCompleted)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                Task {
                    if services.isAsleep {
                        await services.wakeRobot()
                    } else {
                        await services.sleepRobot()
                    }
                }
            } label: {
                Label(services.isAsleep ? "Wake" : "Sleep",
                      systemImage: services.isAsleep ? "sun.max.fill" : "moon.fill")
            }
            .help(services.isAsleep
                  ? "Wake Rocky up — enable motors and recover the neutral pose."
                  : "Send Rocky to sleep — disable motors after the goodbye animation.")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                Task { await services.toggleMic() }
            } label: {
                Label(services.micEnabled ? "Mute mic" : "Unmute mic",
                      systemImage: services.micEnabled ? "mic.fill" : "mic.slash")
            }
            .help(services.micEnabled
                  ? "Stop listening (Rocky's mic is currently live)."
                  : "Start listening so Rocky can hear you say his name.")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                Task { await services.toggleTTSMute() }
            } label: {
                Label(services.ttsMuted ? "Unmute voice" : "Mute voice",
                      systemImage: services.ttsMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
            }
            .help(services.ttsMuted
                  ? "Allow Rocky to speak again."
                  : "Mute Rocky's voice — replies still appear in the conversation.")
        }

        ToolbarItem(placement: .principal) { Spacer() }

        ToolbarItem(placement: .primaryAction) {
            Button {
                if let until = services.healthGlance.tooltip {
                    inspectorPresented = true
                    _ = until  // documented intent: open inspector to Health
                } else {
                    inspectorPresented = true
                }
            } label: {
                Label(services.healthGlance.label,
                      systemImage: services.healthGlance.symbol)
                    .foregroundStyle(services.healthGlance.tint)
            }
            .help(services.healthGlance.tooltip ?? "All systems healthy.")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                inspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Open the engineering drawer: status, activity, memory, motion, vision, raw events.")
        }
    }
}
