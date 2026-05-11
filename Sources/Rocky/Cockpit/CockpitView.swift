import SwiftUI

/// CockpitView — the stage.
///
/// Per `docs/concepts/cockpit-design.md` §3.1, the window's primary
/// content is a portrait + conversation split with a draggable divider.
/// `HSplitView` provides the divider and per-side resize behavior.
///
/// Design §3.2 places the moment-feed strip + "remember" / "diagnose"
/// footer *inside the conversation column* (so they track the splitter
/// when the user resizes). They lived under both columns earlier and
/// stretched across the entire window — fixed by moving them into
/// `ConversationView`.
///
/// Default split: ~40 portrait / 60 conversation. The divider can be
/// dragged either way; minimums prevent the columns from collapsing.
struct CockpitView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        HSplitView {
            PortraitView()
                .frame(minWidth: 320, idealWidth: 420)
            ConversationView()
                .frame(minWidth: 480)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
