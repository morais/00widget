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
    private var contentUpdateTasks: [String: Task<Void, Never>] = [:]
    private var stateUpdateTasks: [String: Task<Void, Never>] = [:]
    private var activityUpdatesTask: Task<Void, Never>?
    private var pushToStartTask: Task<Void, Never>?
    private var latestPushToStartToken: Data?
    private var registeredActivityTokens: [String: String] = [:]
    private var activityTokensInFlight: [String: String] = [:]
    private var registeredStartToken: String?
    private var startTokenInFlight: String?
    #endif

    public init() {
        #if canImport(ActivityKit)
        refreshActiveActivities()
        observeActivityUpdates()
        observePushToStartToken()
        retryCurrentTokens()
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

    public func credentialsDidChange() {
        #if canImport(ActivityKit)
        registeredActivityTokens.removeAll()
        registeredStartToken = nil
        retryCurrentTokens()
        #endif
    }

    #if canImport(ActivityKit)
    /// Starts a demo Live Activity on this device.
    ///
    /// Requested with `pushType: nil` on purpose. A local sample has no
    /// server-issued `activityInstanceId`, so it must never enter the remote
    /// lifecycle: no push token is minted, nothing is registered against the
    /// tenant, and the backend never learns it exists. That separation is why
    /// this is safe to offer again after `Fix remote Live Activity lifecycle`
    /// removed the previous local-start path.
    public func startSample() async throws {
        let session = SampleDataFactory.makeLiveActivitySession()
        guard !activeSessions.contains(where: { $0.isSample }) else { return }
        let (attributes, state) = ZeroZeroWidgetActivityAttributes.from(session)
        _ = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: session.staleAt),
            pushType: nil
        )
        refreshActiveActivities()
    }

    /// Ends every locally generated sample activity. Server-started activities
    /// are left alone.
    public func endSamples() async {
        for activity in Activity<ZeroZeroWidgetActivityAttributes>.activities
        where activity.attributes.activityInstanceId == nil
            && activity.attributes.externalActivityId
                .hasPrefix(ZeroZeroWidgetConstants.sampleCardIdPrefix) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        refreshActiveActivities()
    }

    private func observeActivity(_ activity: Activity<ZeroZeroWidgetActivityAttributes>) {
        let localActivityId = activity.id
        let activityInstanceId = activity.attributes.activityInstanceId
        let externalId = activity.attributes.externalActivityId
        let kind = activity.attributes.kind

        // A local sample is never registered with the backend. `pushType: nil`
        // already means no token is ever minted, but state this explicitly so
        // the invariant does not depend on that detail.
        guard !(activityInstanceId == nil
            && externalId.hasPrefix(ZeroZeroWidgetConstants.sampleCardIdPrefix)) else {
            observeContentAndState(activity)
            return
        }

        if let tokenData = activity.pushToken {
            submitPushToken(
                tokenData,
                localActivityId: localActivityId,
                activityInstanceId: activityInstanceId,
                externalActivityId: externalId,
                kind: kind
            )
        }

        if pushTokenTasks[localActivityId] == nil {
            pushTokenTasks[localActivityId] = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    self?.log.info("Activity push token for \(externalId, privacy: .public)")
                    self?.submitPushToken(
                        tokenData,
                        localActivityId: localActivityId,
                        activityInstanceId: activityInstanceId,
                        externalActivityId: externalId,
                        kind: kind
                    )
                }
            }
        }

        observeContentAndState(activity)
    }

    /// Keeps `activeSessions` in step with an activity's content and lifecycle.
    /// Shared by remote and sample activities — a sample still has to disappear
    /// from the list when it ends, it just never registers a push token.
    private func observeContentAndState(_ activity: Activity<ZeroZeroWidgetActivityAttributes>) {
        let localActivityId = activity.id

        if contentUpdateTasks[localActivityId] == nil {
            contentUpdateTasks[localActivityId] = Task { [weak self] in
                for await _ in activity.contentUpdates {
                    self?.refreshActiveActivities()
                }
            }
        }

        if stateUpdateTasks[localActivityId] == nil {
            stateUpdateTasks[localActivityId] = Task { [weak self] in
                for await _ in activity.activityStateUpdates {
                    self?.refreshActiveActivities()
                }
            }
        }
    }

    private func observeActivityUpdates() {
        activityUpdatesTask?.cancel()
        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<ZeroZeroWidgetActivityAttributes>.activityUpdates {
                self?.log.info("Observed remote activity \(activity.id, privacy: .public)")
                self?.observeActivity(activity)
                self?.refreshActiveActivities()
            }
        }
    }

    private func retryCurrentTokens() {
        if let tokenData = Activity<ZeroZeroWidgetActivityAttributes>.pushToStartToken {
            latestPushToStartToken = tokenData
        }
        if let latestPushToStartToken {
            submitStartToken(latestPushToStartToken)
        }
        for activity in Activity<ZeroZeroWidgetActivityAttributes>.activities {
            observeActivity(activity)
        }
    }

    private func refreshActiveActivities() {
        let activities = Activity<ZeroZeroWidgetActivityAttributes>.activities
        for activity in activities {
            observeActivity(activity)
        }
        activeIds = activities.map {
            $0.attributes.activityInstanceId ?? $0.attributes.externalActivityId
        }
        activeSessions = activities.map { activity in
            let attributes = activity.attributes
            let state = activity.content.state
            return LiveActivitySession(
                activityInstanceId: attributes.activityInstanceId,
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
                countdownGranularity: state.countdownGranularity,
                updatedAt: state.updatedAt,
                staleAt: state.staleAt,
                deepLink: attributes.deepLink
            )
        }
    }

    /// Observes push-to-start tokens for ZeroZeroWidgetActivityAttributes. The
    /// latest value is retained in memory so first-run login can retry it after
    /// credentials become available.
    private func observePushToStartToken() {
        pushToStartTask?.cancel()
        pushToStartTask = Task { [weak self] in
            for await tokenData in Activity<ZeroZeroWidgetActivityAttributes>.pushToStartTokenUpdates {
                self?.latestPushToStartToken = tokenData
                self?.log.info("push-to-start token received")
                self?.submitStartToken(tokenData)
            }
        }
    }

    private func submitStartToken(_ tokenData: Data) {
        let token = tokenData.hexString
        guard registeredStartToken != token, startTokenInFlight != token else { return }
        startTokenInFlight = token
        Task { [weak self] in
            guard let self else { return }
            let registered = await self.registerStartToken(pushToken: token)
            if self.startTokenInFlight == token {
                self.startTokenInFlight = nil
            }
            if registered {
                self.registeredStartToken = token
            }
        }
    }

    private func submitPushToken(
        _ tokenData: Data,
        localActivityId: String,
        activityInstanceId: String?,
        externalActivityId: String,
        kind: LiveActivityKind
    ) {
        let token = tokenData.hexString
        guard
            registeredActivityTokens[localActivityId] != token,
            activityTokensInFlight[localActivityId] != token
        else { return }
        activityTokensInFlight[localActivityId] = token
        Task { [weak self] in
            guard let self else { return }
            let registered = await self.registerPushToken(
                localActivityId: localActivityId,
                activityInstanceId: activityInstanceId,
                externalActivityId: externalActivityId,
                kind: kind,
                pushToken: token
            )
            if self.activityTokensInFlight[localActivityId] == token {
                self.activityTokensInFlight.removeValue(forKey: localActivityId)
            }
            if registered {
                self.registeredActivityTokens[localActivityId] = token
            }
        }
    }

    private func registerStartToken(pushToken: String) async -> Bool {
        guard let config = APIClientConfig.fromSettings() else { return false }
        let client = APIClient(config: config)
        let deviceId = DeviceRegistration.deviceId()
        do {
            try await client.registerLiveActivityStartToken(
                deviceId: deviceId,
                attributesType: "ZeroZeroWidgetActivityAttributes",
                pushToken: pushToken
            )
            return true
        } catch {
            log.error("Failed to register start token: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func registerPushToken(
        localActivityId: String,
        activityInstanceId: String?,
        externalActivityId: String,
        kind: LiveActivityKind,
        pushToken: String
    ) async -> Bool {
        guard let config = APIClientConfig.fromSettings() else { return false }
        let client = APIClient(config: config)
        let deviceId = DeviceRegistration.deviceId()
        do {
            try await client.registerLiveActivity(
                deviceId: deviceId,
                localActivityId: localActivityId,
                activityInstanceId: activityInstanceId,
                externalActivityId: externalActivityId,
                kind: kind,
                pushToken: pushToken
            )
            return true
        } catch {
            log.error("Failed to register activity push token: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
    #endif
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
