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
    @Published public private(set) var activeSessions: [LiveActivitySession] = []
    private var pushTokenTasks: [String: Task<Void, Never>] = [:]
    private var pushToStartTask: Task<Void, Never>?
    private var endingExternalIds = Set<String>()
    #endif

    public init() {
        #if canImport(ActivityKit)
        refreshActiveActivities()
        observePushToStartToken()
        #endif
    }

    public var supported: Bool {
        #if canImport(ActivityKit)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    public func refresh() {
        #if canImport(ActivityKit)
        refreshActiveActivities()
        #endif
    }

    #if canImport(ActivityKit)
    public func start(_ session: LiveActivitySession) async throws {
        endingExternalIds.remove(session.externalActivityId)
        let (attrs, state) = ZeroZeroWidgetActivityAttributes.from(session)
        let content = ActivityContent(state: state, staleDate: session.staleAt)
        let activity = try Activity.request(attributes: attrs, content: content, pushType: .token)
        log.info("Started activity \(activity.id, privacy: .public) for \(session.externalActivityId, privacy: .public)")
        observePushToken(activity: activity, session: session)
        refreshActiveActivities()
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
        refreshActiveActivities()
    }

    public func end(externalActivityId: String, finalState: ZeroZeroWidgetActivityAttributes.ContentState? = nil) async {
        endingExternalIds.insert(externalActivityId)
        for activity in Activity<ZeroZeroWidgetActivityAttributes>.activities where activity.attributes.externalActivityId == externalActivityId {
            let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: .default)
        }
        pushTokenTasks[externalActivityId]?.cancel()
        pushTokenTasks.removeValue(forKey: externalActivityId)
        refreshActiveActivities()
        activeIds.removeAll { $0 == externalActivityId }
        activeSessions.removeAll { $0.externalActivityId == externalActivityId }
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

    private func refreshActiveActivities() {
        let allActivities = Activity<ZeroZeroWidgetActivityAttributes>.activities
        let activityIds = Set(allActivities.map { $0.attributes.externalActivityId })
        endingExternalIds = endingExternalIds.filter { activityIds.contains($0) }

        let activities = allActivities.filter { !endingExternalIds.contains($0.attributes.externalActivityId) }
        activeIds = activities.map { $0.attributes.externalActivityId }
        activeSessions = activities.map { activity in
            let attributes = activity.attributes
            let state = activity.content.state
            return LiveActivitySession(
                externalActivityId: attributes.externalActivityId,
                kind: attributes.kind,
                title: attributes.title,
                subtitle: state.subtitle,
                state: state.state,
                icon: state.icon ?? attributes.icon,
                value: state.value,
                unit: state.unit,
                progress: state.progress,
                endsAt: state.endsAt,
                updatedAt: state.updatedAt,
                staleAt: state.staleAt,
                deepLink: attributes.deepLink
            )
        }
    }

    /// Observes push-to-start tokens for ZeroZeroWidgetActivityAttributes (iOS 17.2+).
    /// One token represents the device's ability to be sent a `start` APNs event for
    /// this attribute type — the backend uses it to start a Live Activity without
    /// the app needing to be open. Tokens fire on first launch after install/reboot.
    private func observePushToStartToken() {
        pushToStartTask?.cancel()
        pushToStartTask = Task { [weak self] in
            for await tokenData in Activity<ZeroZeroWidgetActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self?.log.info("push-to-start token received")
                await self?.registerStartToken(pushToken: hex)
            }
        }
    }

    private func registerStartToken(pushToken: String) async {
        guard let config = APIClientConfig.fromSettings() else { return }
        let client = APIClient(config: config)
        let deviceId = DeviceRegistration.deviceId()
        do {
            try await client.registerLiveActivityStartToken(
                deviceId: deviceId,
                attributesType: "ZeroZeroWidgetActivityAttributes",
                pushToken: pushToken
            )
        } catch {
            log.error("Failed to register start token: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
