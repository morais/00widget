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
    private var reconciliationInProgress = false
    private var serverSessions: [LiveActivitySession] = []
    private var hasLoadedServerSessions = false
    private var recoveryAttemptedAt: [String: Date] = [:]
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

    /// Treats the server's ongoing activity list as authoritative and ends any
    /// remote 00Widget activity that survived locally after its server record
    /// disappeared. This repairs the case where APNs accepted an end event but
    /// the device never applied it. Local sample activities are intentionally
    /// excluded because the server never knows about them.
    public func reconcileWithServer() async {
        #if canImport(ActivityKit)
        refreshActiveActivities()
        guard !reconciliationInProgress else { return }
        guard let config = APIClientConfig.fromSettings() else { return }

        reconciliationInProgress = true
        defer { reconciliationInProgress = false }

        do {
            let client = APIClient(config: config)
            let serverActivities = try await client.fetchLiveActivities()
            serverSessions = serverActivities
            hasLoadedServerSessions = true
            let ongoingInstanceIds = Set(serverActivities.compactMap(\.activityInstanceId))
            let ongoingExternalIds = Set(serverActivities.map(\.externalActivityId))
            let orphanedActivities = Activity<ZeroZeroWidgetActivityAttributes>.activities.filter { activity in
                let attributes = activity.attributes
                if attributes.activityInstanceId == nil,
                   attributes.externalActivityId.hasPrefix(ZeroZeroWidgetConstants.sampleCardIdPrefix) {
                    return false
                }
                if let activityInstanceId = attributes.activityInstanceId {
                    return !ongoingInstanceIds.contains(activityInstanceId)
                }
                return !ongoingExternalIds.contains(attributes.externalActivityId)
            }

            for activity in orphanedActivities {
                log.info(
                    "Ending orphaned local activity \(activity.attributes.externalActivityId, privacy: .public)"
                )
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await recoverMissingActivities(serverActivities, using: client)
            refreshActiveActivities()
        } catch {
            // Reconciliation is fail-safe: an unavailable or unauthorized
            // server must never cause local activities to be ended.
            log.error(
                "Failed to reconcile Live Activities: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }

    public func credentialsDidChange() {
        #if canImport(ActivityKit)
        registeredActivityTokens.removeAll()
        registeredStartToken = nil
        serverSessions = []
        hasLoadedServerSessions = false
        recoveryAttemptedAt = [:]
        refreshActiveActivities()
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
        let localSessions = activities.map { activity in
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
                items: state.items,
                endsAt: state.endsAt,
                countdownGranularity: state.countdownGranularity,
                updatedAt: state.updatedAt,
                staleAt: state.staleAt,
                deepLink: attributes.deepLink
            )
        }
        guard hasLoadedServerSessions else {
            activeSessions = localSessions
            return
        }

        // The server list is authoritative for which remote activities still
        // exist and survives an app update even when ActivityKit no longer
        // enumerates the local instance. Prefer newer local content for an
        // instance so an APNs update received while the screen is open appears
        // immediately without waiting for another server fetch. Local samples
        // never exist on the server, so merge those back in separately.
        let localRemoteSessions = localSessions.filter { !$0.isSample }
        let mergedRemoteSessions = serverSessions.map { serverSession in
            let localSession = localRemoteSessions.first { candidate in
                if let serverInstanceId = serverSession.activityInstanceId,
                   let candidateInstanceId = candidate.activityInstanceId {
                    return serverInstanceId == candidateInstanceId
                }
                return serverSession.externalActivityId == candidate.externalActivityId
            }
            guard let localSession, localSession.updatedAt > serverSession.updatedAt else {
                return serverSession
            }
            return localSession
        }
        activeSessions = mergedRemoteSessions + localSessions.filter(\.isSample)
    }

    private func recoverMissingActivities(
        _ serverActivities: [LiveActivitySession],
        using client: APIClient
    ) async {
        guard supported else { return }
        let localActivities = Activity<ZeroZeroWidgetActivityAttributes>.activities
        let localInstanceIds = Set(localActivities.compactMap(\.attributes.activityInstanceId))
        let localExternalIds = Set(localActivities.map(\.attributes.externalActivityId))

        for activityInstanceId in localInstanceIds {
            recoveryAttemptedAt.removeValue(forKey: activityInstanceId)
        }

        let now = Date()
        let cooldown: TimeInterval = 5 * 60
        let missingInstanceIds = serverActivities.compactMap { session -> String? in
            guard let activityInstanceId = session.activityInstanceId else { return nil }
            let existsLocally = localInstanceIds.contains(activityInstanceId)
                || localExternalIds.contains(session.externalActivityId)
            guard !existsLocally else { return nil }
            if let attemptedAt = recoveryAttemptedAt[activityInstanceId],
               now.timeIntervalSince(attemptedAt) < cooldown {
                return nil
            }
            return activityInstanceId
        }
        guard !missingInstanceIds.isEmpty else { return }

        let currentStartToken = Activity<ZeroZeroWidgetActivityAttributes>.pushToStartToken
            ?? latestPushToStartToken
        guard let currentStartToken else {
            log.info("Deferring Live Activity recovery until a start token is available")
            return
        }
        latestPushToStartToken = currentStartToken
        let token = currentStartToken.hexString
        if registeredStartToken != token {
            let registered = await registerStartToken(pushToken: token)
            guard registered else { return }
            registeredStartToken = token
        }

        for activityInstanceId in missingInstanceIds {
            recoveryAttemptedAt[activityInstanceId] = now
        }
        do {
            try await client.recoverLiveActivities(
                deviceId: DeviceRegistration.deviceId(),
                activityInstanceIds: missingInstanceIds
            )
            log.info("Requested recovery for \(missingInstanceIds.count, privacy: .public) Live Activities")
        } catch {
            log.error("Failed to recover Live Activities: \(error.localizedDescription, privacy: .public)")
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
