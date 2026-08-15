#if ZW_SHARING_ENABLED
import SwiftUI

struct SharingView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var didLoad = false

    var body: some View {
        Form {
            // Guest links are not governed by the server's sharing kill switch
            // or by ZW_SHARING_ENABLED, so this row sits above the notice below
            // and stays useful when account-to-account sharing is off.
            Section {
                NavigationLink("Links you've shared") {
                    SharedGuestLinksView()
                }
            } footer: {
                Text("Read-only QR links. Whoever you show one to does not need to be signed in.")
            }

            if env.sharingDisabledByServer {
                Section {
                    Text("Sharing is disabled on the server.")
                        .foregroundStyle(.secondary)
                }
            }

            if !env.incomingShares.filter({ $0.status == .pending }).isEmpty {
                Section("Pending invites") {
                    ForEach(env.incomingShares.filter { $0.status == .pending }) { share in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(resourceLabel(share))
                                .font(.body)
                            Text(share.ownerEmail ?? share.recipientEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Accept") {
                                    Task { await env.acceptShare(id: share.id) }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Decline", role: .destructive) {
                                    Task { await env.declineShare(id: share.id) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            let acceptedIncoming = env.incomingShares.filter { $0.status == .accepted }
            if !acceptedIncoming.isEmpty {
                Section("Shared with me") {
                    ForEach(acceptedIncoming) { share in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(resourceLabel(share))
                                Text(share.ownerEmail ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop", role: .destructive) {
                                Task { await env.revokeShare(id: share.id) }
                            }
                        }
                    }
                }
            }

            let activeOutgoing = env.outgoingShares.filter { $0.status == .pending || $0.status == .accepted }
            if !activeOutgoing.isEmpty {
                Section("Shared by me") {
                    ForEach(activeOutgoing) { share in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(resourceLabel(share))
                                Text("\(share.recipientEmail) — \(share.status.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                Task { await env.revokeShare(id: share.id) }
                            }
                        }
                    }
                }
            }

            if env.incomingShares.isEmpty && env.outgoingShares.isEmpty && !env.sharingDisabledByServer {
                Section {
                    Text("You haven't shared any widgets yet. Open a widget and tap the Share button.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sharing")
        .refreshable { await env.refreshShares() }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await env.refreshShares()
        }
    }

    private func resourceLabel(_ share: ShareRecord) -> String {
        switch share.resourceKind {
        case .card:
            if let card = env.cards.first(where: { $0.id == share.resourceId }) {
                return card.title
            }
            if let shared = env.sharedCards.first(where: { $0.id == share.resourceId }) {
                return shared.title
            }
            return share.resourceId
        case .activityKind:
            return "Live Activity: \(share.resourceId)"
        }
    }
}

struct ShareCardSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let card: DashboardCard

    @State private var email: String = ""
    @State private var submitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipient") {
                    TextField("name@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                let existing = env.outgoingShares.filter {
                    $0.resourceKind == .card &&
                    $0.resourceId == card.id &&
                    ($0.status == .pending || $0.status == .accepted)
                }
                if !existing.isEmpty {
                    Section("Already shared with") {
                        ForEach(existing) { share in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(share.recipientEmail)
                                    Text(share.status.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    Task { await env.revokeShare(id: share.id) }
                                }
                            }
                        }
                    }
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Share \(card.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(email.isEmpty || submitting)
                }
            }
            .task { await env.refreshShares() }
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        errorText = nil
        do {
            try await env.createShare(
                recipientEmail: email,
                resourceKind: .card,
                resourceId: card.id
            )
            dismiss()
        } catch let error as APIClientError where error.status == 503 {
            errorText = "Sharing is disabled on the server."
        } catch let error as APIClientError where error.status == 409 {
            errorText = "Already shared with that recipient."
        } catch {
            errorText = error.localizedDescription
        }
    }
}

extension LiveActivityKind: Identifiable {
    public var id: String { rawValue }
}

struct ShareActivityKindSheet: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let kind: LiveActivityKind

    @State private var email: String = ""

    @State private var submitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The single most important thing to say, and the previous
                    // copy did not: this is not a share of the activity the
                    // person was looking at. It covers a whole class, including
                    // activities that do not exist yet.
                    Label {
                        Text("This shares **every \(kind.rawValue) Live Activity** on your account — the ones running now and any you start in future — until you revoke it.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)

                    Text("To share only the one activity, close this and choose “Share this activity as a link” instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Recipient") {
                    TextField("name@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                let existing = env.outgoingShares.filter {
                    $0.resourceKind == .activityKind &&
                    $0.resourceId == kind.rawValue &&
                    ($0.status == .pending || $0.status == .accepted)
                }
                if !existing.isEmpty {
                    Section("Already shared with") {
                        ForEach(existing) { share in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(share.recipientEmail)
                                    Text(share.status.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    Task { await env.revokeShare(id: share.id) }
                                }
                            }
                        }
                    }
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Share all \(kind.rawValue) activities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(email.isEmpty || submitting)
                }
            }
            .task { await env.refreshShares() }
        }
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }
        errorText = nil
        do {
            try await env.createShare(
                recipientEmail: email,
                resourceKind: .activityKind,
                resourceId: kind.rawValue
            )
            dismiss()
        } catch let error as APIClientError where error.status == 503 {
            errorText = "Sharing is disabled on the server."
        } catch let error as APIClientError where error.status == 409 {
            errorText = "Already shared with that recipient."
        } catch {
            errorText = error.localizedDescription
        }
    }
}
#endif
