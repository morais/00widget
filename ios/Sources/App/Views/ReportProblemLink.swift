import SwiftUI

/// Reporting for content this account did not publish.
///
/// App Review guideline 1.2 asks for a way to report objectionable content
/// wherever such content can appear, which is why this sits on the detail
/// screen of a card or Live Activity that arrived through a share or a guest
/// link — not only in a settings list somebody would have to think to open.
///
/// The link carries no identifiers. Appending the card or share id would put
/// another tenant's resource id into web server logs, and into the Referer of
/// whatever the support page loads; a report that needs context belongs in a
/// request the app authenticates, not in a URL.
struct ReportProblemLink: View {
    var body: some View {
        Link(destination: ZeroZeroWidgetConstants.Legal.support) {
            Label("Report a problem", systemImage: "exclamationmark.bubble")
        }
    }
}
