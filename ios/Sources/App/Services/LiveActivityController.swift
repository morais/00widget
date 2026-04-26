import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
import os

@MainActor
public final class LiveActivityController: ObservableObject {
    public static let shared = LiveActivityController()

    private let log = Logger(subsystem: "com.example.zerozerowidget", category: "LiveActivity")

    #if canImport(ActivityKit)
    @Published public private(set) var activeIds: [String] = []
    private var pushTokenTasks: [String: Task<Void, Never>] = [:]
    #endif

    public init() {
        #if canImport(ActivityKit)
        refreshActiveIds()
        #endif
    }

    public var supported: Bool {
        #if canImport(ActivityKit)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    #if canImport(ActivityKit)
    public func start(_ session: LiveActivitySession) async throws {
        let (attrs, state) = ZeroZeroWidgetActivityAttributes.from(session)
        let content = ActivityContent(state: state, staleDate: session.staleAt)
        let activity = try Activity.request(attributes: attrs, content: content, pushType: .token)
        log.info("Started activity \(activity.id, privacy: .public) for \(session.externalActivityId, privacy: .public)")
        observePushToken(activity: activity, session: session)
        refreshActiveIds()
    }

    public func update(_ session: LiveActivitySession, alert: AlertConfiguration? = nil) async {
        for activity in Activity<ZeroZeroWidgetActivityAttributes>.activities where activity.attributes.externalActivityId == session.externalActivityId {
            let (_, state) = ZeroZeroWidgetActivityAttributes.from(session)
            let content = ActivityContent(state: state, staleDate: session.staleAt)
            if let alert {
                await activity.update(content, alertConfiguration: alert)
            } else {
                await activity.update(content)
            }
        }
    }

    public func end(externalActivityId: String, finalState: ZeroZeroWidgetActivityAttributes.ContentState? = nil) async {
        for activity in Activity<ZeroZeroWidgetActivityAttributes>.activities where activity.attributes.externalActivityId == externalActivityId {
            let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: .default)
        }
        pushTokenTasks[externalActivityId]?.cancel()
        pushTokenTasks.removeValue(forKey: externalActivityId)
        refreshActiveIds()
    }

    private func observePushToken(activity: Activity<ZeroZeroWidgetActivityAttributes>, session: LiveActivitySession) {
        let externalId = session.externalActivityId
        let kind = session.kind
        let localActivityId = activity.id
        pushTokenTasks[externalId]?.cancel()
        pushTokenTasks[externalId] = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self?.log.info("Activity push token for \(externalId, privacy: .public)")
                await self?.registerPushToken(
                    localActivityId: localActivityId,
                    externalActivityId: externalId,
                    kind: kind,
                    pushToken: hex
                )
            }
        }
    }

    private func registerPushToken(
        localActivityId: String,
        externalActivityId: String,
        kind: LiveActivityKind,
        pushToken: String
    ) async {
        guard let config = APIClientConfig.fromSettings() else { return }
        let client = APIClient(config: config)
        let deviceId = DeviceRegistration.deviceId()
        do {
            try await client.registerLiveActivity(
                deviceId: deviceId,
                localActivityId: localActivityId,
                externalActivityId: externalActivityId,
                kind: kind,
                pushToken: pushToken
            )
        } catch {
            log.error("Failed to register activity push token: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshActiveIds() {
        activeIds = Activity<ZeroZeroWidgetActivityAttributes>.activities.map { $0.attributes.externalActivityId }
    }
    #endif
}
