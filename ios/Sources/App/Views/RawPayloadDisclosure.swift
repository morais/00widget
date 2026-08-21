import SwiftUI

/// The "Raw JSON" and "Example curl" pair shown on a detail screen: what the
/// server holds for this resource, and the request an agent would send to
/// publish it.
///
/// One view rather than a copy per screen, and — importantly — the developer
/// flag is checked in here rather than by each caller. The first version of
/// this option gated the card screen and left the Live Activity screen showing
/// its payload to everyone, because the two screens carried duplicates of the
/// same block and only one of them was edited. A gate a call site can forget
/// is a gate that will be forgotten.
struct RawPayloadDisclosure<Payload: Encodable>: View {
    /// The resource as the server holds it. Encoded with sorted keys so the
    /// same card twice reads the same twice.
    let payload: Payload
    /// Path the equivalent publish would POST to, e.g. `/v1/cards/upsert`.
    let endpoint: String

    // @AppStorage rather than a value read once: a detail screen survives a
    // trip to Settings and back, so a snapshot taken when it was pushed goes
    // stale exactly when somebody has just changed the setting. Pointed at the
    // App Group, matching where `SharedSettings` keeps it.
    @AppStorage(
        ZeroZeroWidgetConstants.UserDefaultsKeys.showRawPayloads,
        store: UserDefaults(suiteName: ZeroZeroWidgetConstants.appGroupIdentifier)
    )
    private var showRawPayloads = false

    @State private var showJson = false
    @State private var showCurl = false

    var body: some View {
        if showRawPayloads {
            VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup("Raw JSON", isExpanded: $showJson) {
                    monospacedBlock(jsonString)
                }
                .font(.headline)

                DisclosureGroup("Example curl", isExpanded: $showCurl) {
                    monospacedBlock(curlExample)
                }
                .font(.headline)
            }
        }
    }

    private func monospacedBlock(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard
            let data = try? encoder.encode(payload),
            let string = String(data: data, encoding: .utf8)
        else {
            return "—"
        }
        return string
    }

    private var curlExample: String {
        // The payload is pasted inside single quotes, so any single quote in
        // it has to close, escape, and reopen them — otherwise a card whose
        // title contains an apostrophe yields a command that will not run.
        let quoted = jsonString.replacingOccurrences(of: "'", with: "'\\''")
        return """
        curl -X POST "$BASE_URL\(endpoint)" \\
          -H "Authorization: Bearer $API_KEY" \\
          -H "Content-Type: application/json" \\
          -d '\(quoted)'
        """
    }
}
