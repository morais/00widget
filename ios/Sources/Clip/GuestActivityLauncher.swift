import Foundation
import ActivityKit
import os

/// Starts and feeds the one Live Activity an App Clip exists to show.
///
/// Deliberately not `LiveActivityController`: that reconciles a whole account's
/// activities against the server, ends orphans and manages start tokens, none
/// of which a clip has any business doing. A clip holds one link, starts one
/// activity, and registers one push token so the owner's updates arrive.
@MainActor
final class GuestActivityLauncher: ObservableObject {
    private static let log = Logger(subsystem: "com.example.zerozerowidget", category: "ClipActivity")

    enum State: Equatable {
        case idle
        case loading
        case running(title: String)
        case card(title: String, value: String?)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Called when the clip has been on screen a moment with no usable link.
    ///
    /// A clip is always launched from a URL, but not always a *complete* one:
    /// a TestFlight invocation carries whatever URL was registered, and the
    /// registered one has no token because the token lives in the fragment and
    /// differs per link. Without this the clip spins on "Opening…" forever and
    /// looks broken rather than under-specified.
    func reportMissingInvocation() {
        guard state == .idle else { return }
        state = .failed(
            "Open a 00Widget link to see what someone shared with you. This opened without one."
        )
    }

    private var pushTokenTask: Task<Void, Never>?

    func open(token: String) async {
        guard GuestToken.looksValid(token) else {
            state = .failed("That link is not valid.")
            return
        }
        guard let baseURL = APIClientConfig.resolvedBaseURL() else {
            state = .failed("This build has no server configured.")
            return
        }
        state = .loading

        let client = APIClient.guest(baseURL: baseURL, token: token)
        let resource: GuestResourceResponse
        do {
            resource = try await client.fetchGuestResource()
        } catch let error as APIClientError where error.status == 401 {
            state = .failed("This link has expired or been revoked.")
            return
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        if let activity = resource.activity {
            await start(activity, client: client)
        } else if let card = resource.card {
            // A clip cannot put a card on the Home Screen — that is the full
            // app's job — so it shows the current value and offers the app.
            state = .card(title: card.title, value: card.value)
        } else {
            state = .failed("That link has nothing to show.")
        }
    }

    private func start(_ session: LiveActivitySession, client: APIClient) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            state = .failed("Live Activities are turned off for this device. Turn them on in Settings to follow this.")
            return
        }
        let (attributes, content) = ZeroZeroWidgetActivityAttributes.from(session)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: session.staleAt),
                pushType: .token
            )
            state = .running(title: session.title)
            observePushToken(of: activity, client: client)
        } catch {
            Self.log.error("clip activity start failed: \(error.localizedDescription, privacy: .public)")
            state = .failed("Could not start the Live Activity.")
        }
    }

    /// Hands the activity's push token to the server under the guest
    /// credential. Without this the activity appears once and never changes,
    /// which is the whole thing a clip is for.
    private func observePushToken(
        of activity: Activity<ZeroZeroWidgetActivityAttributes>,
        client: APIClient
    ) {
        let localActivityId = activity.id
        pushTokenTask?.cancel()
        pushTokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                do {
                    try await client.registerGuestActivity(
                        // The App Group's device id, so a later install of the full app is
                        // recognised as the same device rather than a second one.
                        deviceId: SharedSettings.deviceId(),
                        localActivityId: localActivityId,
                        pushToken: hex
                    )
                    Self.log.info("clip registered guest activity push token")
                } catch {
                    Self.log.error(
                        "clip token registration failed: \(error.localizedDescription, privacy: .public)"
                    )
                    await MainActor.run {
                        self?.state = .failed("Could not subscribe to updates for this activity.")
                    }
                }
            }
        }
    }
}
