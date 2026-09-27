import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class RemoteCodexStore {
    private static let maxQueuedInteractions = 16

    enum ConnectionState {
        case disconnected, connecting, ready, running
        case failed(String)
    }

    private enum RequestKind {
        case initialize
        case threadList(append: Bool)
        case modelList
        case threadStart
        case threadRead(threadID: String, title: String, model: String?, preserveMessages: Bool)
        case threadTurnsList(initial: Bool)
        case threadResumeForSend(text: String)
        case turnStart(text: String, canResumeIfMissing: Bool)

        var diagnosticsName: String {
            switch self {
            case .initialize: "initialize"
            case .threadList(let append): append ? "threadList.append" : "threadList.refresh"
            case .modelList: "modelList"
            case .threadStart: "threadStart"
            case .threadRead: "threadRead"
            case .threadTurnsList(let initial): initial ? "threadTurnsList.initial" : "threadTurnsList.earlier"
            case .threadResumeForSend: "threadResumeForSend"
            case .turnStart: "turnStart"
            }
        }
    }

    private struct PendingRequest {
        let kind: RequestKind
        let method: String
        let sentAt: ContinuousClock.Instant
    }

    private struct EndpointCandidate: Sendable {
        let url: String
        let kind: String
        let trustedOverlayPlaintext: Bool
    }

    private struct EndpointAttempt: Sendable {
        let candidate: EndpointCandidate
        let targets: [RemoteTarget]?
        let remoteError: RemoteHostError?
        let errorDescription: String?
    }

    private struct PendingApprovalRequest {
        let id: CodexRequestID
        let method: String
        let params: [String: Any]
        let prompt: RemoteApprovalPrompt
    }

    private struct PendingUserInputRequest {
        let id: CodexRequestID
        let prompt: RemoteUserInputPrompt
    }

    private struct PendingMcpElicitationRequest {
        let id: CodexRequestID
        let prompt: RemoteMcpElicitationPrompt
    }

    var serverURL = UserDefaults.standard.string(forKey: "codexRemote.serverURL")
        ?? RemoteCredentialStore.loadServerURL()
        ?? ""
    var targets: [RemoteTarget] = []
    var selectedTargetID = UserDefaults.standard.string(forKey: "codexRemote.targetID")
        ?? RemoteCredentialStore.loadTargetID()
    var capabilityToken = RemoteCredentialStore.loadToken() ?? ""
    var hasSavedPairing = RemoteCredentialStore.loadToken() != nil
    var connectionEndpoints = RemoteCredentialStore.loadEndpoints()
    var workingDirectory = UserDefaults.standard.string(forKey: "codexRemote.workingDirectory")
        ?? ""
    var draft = ""
    var messages: [ChatMessage] = []
    var state: ConnectionState = .disconnected {
        didSet {
            diagnostics.record("state.changed", fields: [
                "from": stateName(oldValue),
                "to": stateName(state)
            ])
        }
    }
    var threads: [RemoteThreadSummary] = []
    var chatCatalogEntries: [RemoteChatCatalogEntry] = []
    var chatProjects: [RemoteChatProject] = []
    var hasLoadedChatCatalog = false
    var models: [RemoteModelOption] = []
    var selectedModel: String?
    var showingThreadList = true {
        didSet {
            guard oldValue != showingThreadList else { return }
            diagnostics.record("ui.route.changed", fields: [
                "from": oldValue ? "threadList" : "conversation",
                "to": showingThreadList ? "threadList" : "conversation",
                "threadID": threadID ?? ""
            ])
            schedulePresentationSnapshotSave()
        }
    }
    var isLoadingThreads = false
    var isLoadingChatCatalog = false
    var isLoadingCloudTranscript = false
    var isLoadingModels = false
    var isLoadingTargets = false
    var isLoadingEarlierTurns = false
    var isOpeningThread = false {
        didSet {
            guard oldValue != isOpeningThread else { return }
            diagnostics.record("ui.threadOpening.changed", fields: ["isOpening": isOpeningThread])
        }
    }
    var isPreparingFastChat = false
    var lastError: String? {
        didSet {
            guard oldValue != lastError else { return }
            diagnostics.record("ui.lastError.changed", fields: [
                "hasError": lastError != nil,
                "message": lastError ?? ""
            ])
        }
    }
    var approvalPrompt: RemoteApprovalPrompt?
    var userInputPrompt: RemoteUserInputPrompt?
    var mcpElicitationPrompt: RemoteMcpElicitationPrompt?
    var presentationLastSyncedAt: Date?

    private var wasBackgrounded = false
    private var sceneIsActive = true
    private var preservePresentationOnNextConnect = false
    private var connectionGeneration = 0
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var trustedOverlayPlaintext = false
    private var threadID: String?
    private var threadCanAcceptDirectInput: Bool?
    private var threadHasActiveWriter = false
    private var activeThreadTitle: String?
    private var activeCloudCatalogEntry: RemoteChatCatalogEntry?
    private var cloudTranscriptGeneration = 0
    var isCloudChatMirror = false
    var cloudChatActivity = "idle"
    var cloudChatIsPartial = false
    var cloudChatCanSendText = false
    var cloudChatCanAttach = false
    var stagedCloudAttachments: [RemoteChatAttachment] = []
    var isUploadingCloudAttachment = false
    var isSendingCloudMessage = false
    private var cloudSendRequiresRefresh = false
    private var cloudRemoteMessageCount = 0
    private var cloudConversationCache: [String: RemotePresentationSnapshot.CachedCloudConversation] = [:]
    private var pendingCloudSendRequestID: String?
    private var pendingCloudSendConversationID: String?
    private var pendingCloudSendText: String?
    private var pendingCloudSendAttachmentIDs: [String] = []
    private var pendingCloudSendBaselineMessageCount = 0
    private var activeAssistantMessageID: UUID?
    private var pendingNewThreadMessage: String?
    private var liveActivityMessageIDs: [String: UUID] = [:]
    private var nextRequestID = 1
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var activeApprovalRequest: PendingApprovalRequest?
    private var approvalQueue: [PendingApprovalRequest] = []
    private var activeUserInputRequest: PendingUserInputRequest?
    private var userInputQueue: [PendingUserInputRequest] = []
    private var activeMcpElicitationRequest: PendingMcpElicitationRequest?
    private var mcpElicitationQueue: [PendingMcpElicitationRequest] = []
    private var nextThreadCursor: String?
    private var nextTurnCursor: String?
    private let presentationSnapshotStore = RemotePresentationSnapshotStore()
    private var presentationSnapshot: RemotePresentationSnapshot?
    private var presentationSnapshotSaveTask: Task<Void, Never>?
    let diagnostics = RemoteDiagnostics.shared
    let hostClient = RemoteHostClient()
    private let codexClient = CodexAppServerClient()

    init() {
        restorePresentationSnapshotOnLaunch()
    }

    var diagnosticsURL: URL { diagnostics.fileURL }

    var isConnected: Bool {
        switch state { case .ready, .running: true; default: false }
    }
    var isConnecting: Bool { if case .connecting = state { true } else { false } }
    var canSwitchThreads: Bool { if case .ready = state { true } else { false } }
    var selectedTarget: RemoteTarget? {
        guard let selectedTargetID else { return nil }
        return targets.first { $0.id == selectedTargetID }
    }
    var hasMultipleTargets: Bool { targets.count > 1 }
    var selectedTargetPresentationName: String? {
        selectedTarget.map(targetPresentationName)
    }
    func targetPresentationName(_ target: RemoteTarget) -> String {
        target.presentationName(targetCount: targets.count)
    }
    var canChangeTarget: Bool {
        if isConnecting || isPreparingFastChat { return false }
        if case .running = state { return false }
        return true
    }
    var canPrepareFastChat: Bool {
        selectedTarget?.chatMirrorNeedsRelaunch == true
            && hasSavedPairing
            && !isPreparingFastChat
    }
    var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isCloudChatMirror {
            let hasAttachments = !stagedCloudAttachments.isEmpty
            return canSwitchThreads
                && activeCloudCatalogEntry != nil
                && cloudChatCanSendText
                && !showingThreadList
                && !isSendingCloudMessage
                && !isUploadingCloudAttachment
                && !cloudSendRequiresRefresh
                && cloudChatActivity != "streaming"
                && (hasText || hasAttachments)
        }
        return canSwitchThreads && threadID != nil && !showingThreadList && hasText
    }
    var canStageCloudAttachment: Bool {
        isCloudChatMirror
            && cloudChatCanAttach
            && canSwitchThreads
            && !showingThreadList
            && !isSendingCloudMessage
            && !isUploadingCloudAttachment
            && !cloudSendRequiresRefresh
            && cloudChatActivity != "streaming"
            && stagedCloudAttachments.count < 4
    }
    var hasMoreThreads: Bool { nextThreadCursor != nil }
    var hasPresentationContent: Bool {
        !threads.isEmpty || !chatCatalogEntries.isEmpty || threadID != nil || !messages.isEmpty
    }
    var isShowingCachedPresentation: Bool {
        hasPresentationContent && !isConnected
    }
    var navigationTitle: String {
        showingThreadList ? (selectedTargetPresentationName ?? "Conversations") : (activeThreadTitle ?? "Conversation")
    }
    var selectedModelDisplayName: String {
        guard let selectedModel else { return "Model" }
        return modelDisplayName(for: selectedModel)
    }
    var statusText: String {
        if isCloudChatMirror {
            if isLoadingCloudTranscript { return messages.isEmpty ? "Loading Desktop mirror…" : "Refreshing Desktop mirror…" }
            if cloudSendRequiresRefresh { return "Refresh to confirm the last Chat message before retrying" }
            if isSendingCloudMessage { return "Sending through ChatGPT Desktop…" }
            if cloudChatActivity == "streaming" { return "ChatGPT is responding…" }
            return cloudChatIsPartial ? "Desktop mirror · visible messages" : "Desktop mirror"
        }
        return switch state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting to Mac…"
        case .ready: "Connected"
        case .running: "Generating response…"
        case .failed(let message): "Connection error: \(message)"
        }
    }
    var statusColor: Color {
        switch state {
        case .ready: .green
        case .running, .connecting: .orange
        case .disconnected: .secondary
        case .failed: .red
        }
    }

    private func restorePresentationSnapshotOnLaunch() {
        guard let snapshot = presentationSnapshotStore.load() else {
            diagnostics.record("presentationSnapshot.load.missing", level: .debug)
            return
        }
        presentationSnapshot = snapshot
        if !snapshot.targets.isEmpty {
            targets = snapshot.targets
        }
        let preferredID: String?
        if let selectedTargetID,
           snapshot.targets.contains(where: { $0.id == selectedTargetID }) {
            preferredID = selectedTargetID
        } else {
            preferredID = snapshot.selectedTargetID ?? snapshot.targets.first?.id
        }
        if let preferredID {
            selectedTargetID = preferredID
            _ = restorePresentationSnapshot(for: preferredID)
        }
        diagnostics.record("presentationSnapshot.loaded", fields: [
            "targetCount": snapshot.targets.count,
            "presentationCount": snapshot.presentations.count,
            "hasSelectedTarget": preferredID != nil
        ])
    }

    @discardableResult
    private func restorePresentationSnapshot(for targetID: String) -> Bool {
        guard let presentation = presentationSnapshot?.presentations[targetID] else {
            return false
        }
        threads = presentation.threads
        chatCatalogEntries = presentation.chatCatalogEntries
        chatProjects = presentation.chatProjects
        hasLoadedChatCatalog = presentation.hasLoadedChatCatalog
        models = presentation.models
        selectedModel = presentation.selectedModel
        threadID = presentation.threadID
        activeThreadTitle = presentation.activeThreadTitle
        messages = presentation.messages
        isCloudChatMirror = presentation.isCloudChatMirror
        cloudChatIsPartial = presentation.cloudChatIsPartial
        cloudRemoteMessageCount = presentation.cloudRemoteMessageCount
        cloudConversationCache = presentation.cloudConversationCache ?? [:]
        cloudChatActivity = "idle"
        cloudChatCanSendText = false
        cloudChatCanAttach = false
        cloudSendRequiresRefresh = false
        stagedCloudAttachments = []
        isUploadingCloudAttachment = false
        isSendingCloudMessage = false
        pendingCloudSendRequestID = nil
        pendingCloudSendConversationID = nil
        pendingCloudSendText = nil
        pendingCloudSendAttachmentIDs = []
        pendingCloudSendBaselineMessageCount = 0
        threadCanAcceptDirectInput = nil
        threadHasActiveWriter = false
        activeAssistantMessageID = nil
        liveActivityMessageIDs.removeAll()
        nextThreadCursor = nil
        nextTurnCursor = nil
        activeCloudCatalogEntry = presentation.activeCloudConversationID.flatMap { conversationID in
            chatCatalogEntries.first(where: { $0.id == conversationID })
        }
        let canRestoreConversation = presentation.isCloudChatMirror
            ? activeCloudCatalogEntry != nil
            : presentation.threadID != nil
        showingThreadList = presentation.showingThreadList || !canRestoreConversation
        presentationLastSyncedAt = presentation.savedAt
        diagnostics.record("presentationSnapshot.presentationRestored", fields: [
            "targetID": targetID,
            "threadCount": threads.count,
            "chatCount": chatCatalogEntries.count,
            "messageCount": messages.count,
            "conversationRestored": !showingThreadList
        ])
        return true
    }

    private func schedulePresentationSnapshotSave() {
        presentationSnapshotSaveTask?.cancel()
        presentationSnapshotSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persistPresentationSnapshotNow()
        }
    }

    private func persistPresentationSnapshotNow() {
        presentationSnapshotSaveTask?.cancel()
        presentationSnapshotSaveTask = nil
        guard let targetID = selectedTargetID else { return }
        let savedAt = Date()
        let current = RemotePresentationSnapshot.TargetPresentation(
            targetID: targetID,
            savedAt: savedAt,
            threads: threads,
            chatCatalogEntries: chatCatalogEntries,
            chatProjects: chatProjects,
            hasLoadedChatCatalog: hasLoadedChatCatalog,
            models: models,
            selectedModel: selectedModel,
            showingThreadList: showingThreadList,
            threadID: threadID,
            activeThreadTitle: activeThreadTitle,
            messages: messages,
            isCloudChatMirror: isCloudChatMirror,
            activeCloudConversationID: activeCloudCatalogEntry?.id,
            cloudChatIsPartial: cloudChatIsPartial,
            cloudRemoteMessageCount: cloudRemoteMessageCount,
            cloudConversationCache: cloudConversationCache
        ).bounded()
        var presentations = presentationSnapshot?.presentations ?? [:]
        presentations[targetID] = current
        let snapshotTargets = targets.isEmpty ? (presentationSnapshot?.targets ?? []) : targets
        let snapshot = RemotePresentationSnapshot(
            version: RemotePresentationSnapshot.currentVersion,
            savedAt: savedAt,
            selectedTargetID: targetID,
            targets: snapshotTargets,
            presentations: presentations
        ).bounded()
        do {
            try presentationSnapshotStore.save(snapshot)
            presentationSnapshot = snapshot
            presentationLastSyncedAt = current.savedAt
            diagnostics.record("presentationSnapshot.saved", level: .debug, fields: [
                "targetID": targetID,
                "threadCount": current.threads.count,
                "chatCount": current.chatCatalogEntries.count,
                "messageCount": current.messages.count
            ])
        } catch {
            diagnostics.record("presentationSnapshot.saveFailed", level: .warning, fields: errorFields(error))
        }
    }

    private func scheduleReconnect(reason: String, immediate: Bool = false) {
        guard sceneIsActive, hasSavedPairing, !isConnected, !isConnecting else { return }
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        let delayMilliseconds: Int
        if immediate {
            delayMilliseconds = 0
        } else {
            delayMilliseconds = min(500 * (1 << min(attempt, 5)), 8_000)
        }
        reconnectAttempt = min(attempt + 1, 6)
        diagnostics.record("connection.reconnect.scheduled", fields: [
            "reason": reason,
            "attempt": attempt + 1,
            "delayMs": delayMilliseconds,
            "hasPresentation": hasPresentationContent
        ])
        reconnectTask = Task { @MainActor [weak self] in
            if delayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
            guard let self,
                  !Task.isCancelled,
                  self.sceneIsActive,
                  self.hasSavedPairing,
                  !self.isConnected,
                  !self.isConnecting
            else { return }
            self.diagnostics.record("connection.reconnect.started", fields: [
                "reason": reason,
                "attempt": attempt + 1
            ])
            self.connect(preservingPresentation: self.hasPresentationContent)
        }
    }

    func connect(preservingPresentation: Bool = false) {
        guard !isConnecting else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.connectAsync(preservingPresentation: preservingPresentation, requestedGeneration: generation)
        }
    }

    func connectAsync(preservingPresentation: Bool = false, requestedGeneration: Int? = nil) async {
        let generation: Int
        if let supplied = requestedGeneration {
            generation = supplied
        } else {
            connectionGeneration += 1
            generation = connectionGeneration
        }
        let cachedThreadID = preservingPresentation && !showingThreadList ? threadID : nil
        let cachedThreadTitle = activeThreadTitle
        let cachedThreadModel = selectedModel
        preservePresentationOnNextConnect = preservingPresentation
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostics.record("connection.connect.requested", fields: [
            "serverURL": serverURL,
            "targetID": selectedTargetID ?? "",
            "workingDirectory": workingDirectory,
            "tokenLength": capabilityToken.count
        ])
        disconnect(
            resetState: false,
            reason: "connect.reset",
            preservePresentation: preservingPresentation,
            invalidateConnectionAttempt: false
        )
        guard isCurrentConnection(generation) else { return }
        state = .connecting
        lastError = nil
        if !preservingPresentation {
            showingThreadList = true
        }

        do {
            let token = capabilityToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw RemoteHostError.missingPairingToken }
            let connection = try await discoverTargets(token: token)
            try Task.checkCancellation()
            guard isCurrentConnection(generation) else { return }
            serverURL = connection.baseURL
            trustedOverlayPlaintext = connection.trustedOverlayPlaintext
            let discovered = connection.targets
            targets = discovered
            selectedTargetID = preferredTargetID(
                in: discovered,
                preserving: selectedTargetID
            )
            schedulePresentationSnapshotSave()
            guard var target = selectedTarget else {
                throw RemoteHostError.httpStatus(404, "no-targets")
            }

            if target.activationState != .ready {
                try await hostClient.activate(
                    target: target,
                    baseURL: serverURL,
                    token: token,
                    allowTrustedOverlayPlaintext: connection.trustedOverlayPlaintext
                )
                try Task.checkCancellation()
                guard isCurrentConnection(generation) else { return }
                let refreshed = try await hostClient.fetchTargets(
                    baseURL: serverURL,
                    token: token,
                    allowTrustedOverlayPlaintext: connection.trustedOverlayPlaintext
                )
                try Task.checkCancellation()
                guard isCurrentConnection(generation) else { return }
                targets = refreshed
                guard let refreshedTarget = refreshed.first(where: { $0.id == target.id }) else {
                    throw RemoteHostError.httpStatus(404, "target-disappeared")
                }
                target = refreshedTarget
                schedulePresentationSnapshotSave()
            }
            guard target.activationState == .ready else {
                throw RemoteHostError.httpStatus(409, target.activationState.rawValue)
            }

            let url = try hostClient.webSocketURL(
                baseURL: serverURL,
                target: target,
                allowTrustedOverlayPlaintext: connection.trustedOverlayPlaintext
            )
            UserDefaults.standard.set(serverURL, forKey: "codexRemote.serverURL")
            UserDefaults.standard.set(target.id, forKey: "codexRemote.targetID")
            UserDefaults.standard.set(workingDirectory, forKey: "codexRemote.workingDirectory")
            selectedTargetID = target.id
            await refreshConnectionEndpoints(
                token: token,
                allowTrustedOverlayPlaintext: connection.trustedOverlayPlaintext
            )
            try Task.checkCancellation()
            guard isCurrentConnection(generation) else { return }

            codexClient.connect(
                url: url,
                token: token,
                onResponse: { [weak self] id, object in self?.handleResponse(id: id, object: object) },
                onNotification: { [weak self] method, params in self?.handleNotification(method: method, params: params) },
                onServerRequest: { [weak self] id, method, params in
                    self?.handleServerRequest(id: id, method: method, params: params)
                },
                onFailure: { [weak self] error in self?.handleTransportFailure(error, generation: generation) }
            )
            sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "PluraMobile",
                        "title": "Plura Mobile",
                        "version": "0.1"
                    ],
                    "capabilities": ["experimentalApi": true, "requestAttestation": false]
                ],
                kind: .initialize
            )
            if preservingPresentation, let cachedThreadID {
                threadID = cachedThreadID
                activeThreadTitle = cachedThreadTitle
                selectedModel = cachedThreadModel
            }
            if isCurrentConnection(generation) {
                connectTask = nil
            }
        } catch {
            if error is CancellationError || !isCurrentConnection(generation) {
                diagnostics.record("connection.connect.cancelled", level: .debug, fields: ["generation": generation])
                return
            }
            diagnostics.record("connection.connect.failed", level: .error, fields: errorFields(error))
            state = .failed(error.localizedDescription)
            connectTask = nil
            scheduleReconnect(reason: "connect.failed")
        }
    }

    func forgetPairing() {
        do {
            try RemoteCredentialStore.deletePairing()
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            disconnect(
                resetState: true,
                reason: "pairing.forgotten",
                preservePresentation: false,
                invalidateConnectionAttempt: true
            )
            do {
                try presentationSnapshotStore.delete()
            } catch {
                diagnostics.record("presentationSnapshot.deleteFailed", level: .warning, fields: errorFields(error))
            }
            presentationSnapshot = nil
            presentationLastSyncedAt = nil
            capabilityToken = ""
            hasSavedPairing = false
            connectionEndpoints = []
            serverURL = ""
            selectedTargetID = nil
            targets = []
            UserDefaults.standard.removeObject(forKey: "codexRemote.serverURL")
            UserDefaults.standard.removeObject(forKey: "codexRemote.targetID")
            diagnostics.record("pairing.forgotten")
        } catch {
            diagnostics.record("pairing.keychain.deleteFailed", level: .error, fields: [
                "error": String(describing: error)
            ])
            lastError = "Could not remove the saved pairing"
        }
    }

    func disconnect() {
        wasBackgrounded = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        disconnect(resetState: true, reason: "user", preservePresentation: false, invalidateConnectionAttempt: true)
    }

    func selectTarget(_ target: RemoteTarget) {
        guard target.id != selectedTargetID else { return }
        persistPresentationSnapshotNow()
        let reconnect = codexClient.isActive || isConnected || isConnecting
        disconnect(
            resetState: reconnect,
            reason: "target.switch",
            preservePresentation: false,
            invalidateConnectionAttempt: true
        )
        let previous = selectedTargetID
        selectedTargetID = target.id
        UserDefaults.standard.set(target.id, forKey: "codexRemote.targetID")
        let restoredPresentation = restorePresentationSnapshot(for: target.id)
        diagnostics.record("target.changed", fields: [
            "from": previous ?? "",
            "to": target.id,
            "reconnect": reconnect,
            "restoredPresentation": restoredPresentation
        ])
        if hasSavedPairing {
            connect(preservingPresentation: restoredPresentation)
        }
    }

    func refreshTargets() {
        guard !isLoadingTargets else { return }
        Task { await refreshTargetsAsync() }
    }

    func prepareFastChat() {
        guard canPrepareFastChat,
              let target = selectedTarget
        else { return }
        isPreparingFastChat = true
        lastError = nil
        persistPresentationSnapshotNow()
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnect(
            resetState: true,
            reason: "chat.prepare",
            preservePresentation: true,
            invalidateConnectionAttempt: true
        )
        state = .connecting
        let expectedTargetID = target.id
        let baseURL = serverURL
        let token = capabilityToken
        let allowTrustedOverlayPlaintext = trustedOverlayPlaintext
        diagnostics.record("target.chatPrepare.requested", fields: [
            "targetID": expectedTargetID,
            "allowRelaunch": true
        ])
        Task { [weak self] in
            guard let self else { return }
            do {
                try await hostClient.prepareChat(
                    target: target,
                    allowRelaunch: true,
                    baseURL: baseURL,
                    token: token,
                    allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
                )
                guard selectedTargetID == expectedTargetID else {
                    isPreparingFastChat = false
                    return
                }
                isPreparingFastChat = false
                diagnostics.record("target.chatPrepare.completed", fields: [
                    "targetID": expectedTargetID
                ])
                connect(preservingPresentation: hasPresentationContent)
            } catch {
                guard selectedTargetID == expectedTargetID else {
                    isPreparingFastChat = false
                    return
                }
                isPreparingFastChat = false
                state = .failed(error.localizedDescription)
                lastError = error.localizedDescription
                diagnostics.record("target.chatPrepare.failed", level: .warning, fields: errorFields(error))
            }
        }
    }

    private func refreshTargetsAsync() async {
        isLoadingTargets = true
        defer { isLoadingTargets = false }
        do {
            let connection = try await discoverTargets(token: capabilityToken)
            serverURL = connection.baseURL
            let discovered = connection.targets
            targets = discovered
            selectedTargetID = preferredTargetID(
                in: discovered,
                preserving: selectedTargetID
            )
            schedulePresentationSnapshotSave()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func discoverTargets(
        token: String
    ) async throws -> (baseURL: String, targets: [RemoteTarget], trustedOverlayPlaintext: Bool) {
        var candidates: [EndpointCandidate] = []
        let current = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            let saved = connectionEndpoints.first(where: { $0.url == current })
            candidates.append(EndpointCandidate(
                url: current,
                kind: saved?.kind ?? "manual",
                trustedOverlayPlaintext: saved.map { $0.kind != "lan" } ?? false
            ))
        }
        candidates.append(contentsOf: connectionEndpoints.sorted { $0.priority < $1.priority }.map {
            EndpointCandidate(url: $0.url, kind: $0.kind, trustedOverlayPlaintext: $0.kind != "lan")
        })
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.url).inserted }
        guard !candidates.isEmpty else { throw RemoteHostError.invalidBaseURL }

        diagnostics.record("connection.endpointRace.started", fields: [
            "candidateCount": candidates.count,
            "kinds": candidates.map(\.kind)
        ])
        return try await withThrowingTaskGroup(of: EndpointAttempt.self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    if index > 0 {
                        try await Task.sleep(for: .milliseconds(150 * index))
                    }
                    do {
                        let discovered = try await RemoteHostClient().fetchTargets(
                            baseURL: candidate.url,
                            token: token,
                            allowTrustedOverlayPlaintext: candidate.trustedOverlayPlaintext
                        )
                        return EndpointAttempt(
                            candidate: candidate,
                            targets: discovered,
                            remoteError: nil,
                            errorDescription: nil
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as RemoteHostError {
                        return EndpointAttempt(
                            candidate: candidate,
                            targets: nil,
                            remoteError: error,
                            errorDescription: String(describing: error)
                        )
                    } catch {
                        return EndpointAttempt(
                            candidate: candidate,
                            targets: nil,
                            remoteError: nil,
                            errorDescription: String(describing: error)
                        )
                    }
                }
            }

            var meaningfulRemoteError: RemoteHostError?
            while let attempt = try await group.next() {
                if let discovered = attempt.targets {
                    group.cancelAll()
                    diagnostics.record("connection.endpoint.selected", fields: [
                        "kind": attempt.candidate.kind,
                        "raced": candidates.count > 1
                    ])
                    return (
                        attempt.candidate.url,
                        discovered,
                        attempt.candidate.trustedOverlayPlaintext
                    )
                }
                if meaningfulRemoteError == nil,
                   let remoteError = attempt.remoteError,
                   remoteError.shouldSurfaceAfterEndpointRace {
                    meaningfulRemoteError = remoteError
                }
                diagnostics.record("connection.endpoint.failed", level: .warning, fields: [
                    "kind": attempt.candidate.kind,
                    "error": attempt.errorDescription ?? "unknown"
                ])
            }
            if let meaningfulRemoteError { throw meaningfulRemoteError }
            throw RemoteHostError.httpStatus(503, "host-unreachable")
        }
    }

    private func refreshConnectionEndpoints(
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async {
        do {
            let discovered = try await hostClient.fetchConnectionInfo(
                baseURL: serverURL,
                token: token,
                allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
            )
            if !discovered.isEmpty {
                connectionEndpoints = discovered
                try RemoteCredentialStore.saveEndpoints(discovered)
                diagnostics.record("connection.endpoints.updated", fields: [
                    "count": discovered.count,
                    "kinds": Dictionary(grouping: discovered, by: \.kind).mapValues(\.count)
                ])
            }
        } catch {
            diagnostics.record("connection.endpoints.refreshFailed", level: .warning, fields: [
                "error": String(describing: error)
            ])
        }
    }
    func refreshThreads() { requestThreads(append: false) }
    func loadMoreThreads() { requestThreads(append: true) }

    func clearDiagnostics() {
        diagnostics.clear()
    }

    private func preferredTargetID(
        in discovered: [RemoteTarget],
        preserving current: String?
    ) -> String? {
        if let current, discovered.contains(where: { $0.id == current }) {
            return current
        }
        if let primary = discovered.first(where: \.isPrimaryTarget) {
            return primary.id
        }
        let ready = discovered.filter { $0.activationState == .ready }
        if ready.count == 1 {
            return ready[0].id
        }
        if let available = discovered.first(where: { $0.activationState == .available }) {
            return available.id
        }
        return discovered.first?.id
    }

    func handleScenePhase(_ phase: ScenePhase) {
        let value: String
        switch phase {
        case .active: value = "active"
        case .inactive: value = "inactive"
        case .background: value = "background"
        @unknown default: value = "unknown"
        }
        diagnostics.record("scene.phase.changed", fields: ["phase": value])

        switch phase {
        case .background:
            wasBackgrounded = true
            sceneIsActive = false
            reconnectTask?.cancel()
            reconnectTask = nil
            persistPresentationSnapshotNow()
            diagnostics.record("scene.background.connectionPreserved", fields: [
                "hasSocket": codexClient.isActive,
                "isConnecting": isConnecting,
                "state": stateName(state)
            ])
        case .active:
            sceneIsActive = true
            guard wasBackgrounded else { return }
            wasBackgrounded = false
            if isConnecting || (codexClient.isActive && stateIsReadyOrRunning) {
                diagnostics.record("scene.active.connectionRetained", fields: [
                    "hasSocket": codexClient.isActive,
                    "isConnecting": isConnecting,
                    "state": stateName(state)
                ])
                if isCloudChatMirror, activeCloudCatalogEntry != nil, !isLoadingCloudTranscript {
                    diagnostics.record("scene.active.cloudRefreshRequested", level: .debug)
                    refreshActiveCloudChat()
                }
            } else if hasSavedPairing {
                diagnostics.record("scene.active.reconnectRequested", fields: ["state": stateName(state)])
                scheduleReconnect(reason: "scene.active", immediate: true)
            }
        case .inactive:
            sceneIsActive = false
            break
        @unknown default:
            break
        }
    }

    func refreshModels() {
        guard codexClient.isActive, isConnected, !isLoadingModels else {
            diagnostics.record("models.refresh.skipped", level: .debug, fields: [
                "hasSocket": codexClient.isActive,
                "isConnected": isConnected,
                "isLoading": isLoadingModels
            ])
            return
        }
        diagnostics.record("models.refresh.requested")
        isLoadingModels = true
        sendRequest(method: "model/list", params: ["includeHidden": false, "limit": 100], kind: .modelList)
    }

    func refreshChatCatalog() {
        guard isConnected, !isLoadingChatCatalog, let target = selectedTarget else { return }
        let generation = connectionGeneration
        let targetID = target.id
        let catalogBaseURL = serverURL
        let catalogToken = capabilityToken
        let catalogAllowsTrustedOverlayPlaintext = trustedOverlayPlaintext
        isLoadingChatCatalog = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await hostClient.fetchChatCatalog(
                    target: target,
                    baseURL: catalogBaseURL,
                    token: catalogToken,
                    allowTrustedOverlayPlaintext: catalogAllowsTrustedOverlayPlaintext
                )
                guard isCurrentConnection(generation), selectedTargetID == targetID else {
                    diagnostics.record("chatCatalog.staleResponseDropped", level: .debug, fields: [
                        "generation": generation,
                        "targetID": targetID
                    ])
                    return
                }
                chatCatalogEntries = catalog.entries
                chatProjects = catalog.projects
                hasLoadedChatCatalog = true
                schedulePresentationSnapshotSave()
                diagnostics.record("chatCatalog.applied", fields: [
                    "entryCount": catalog.entries.count,
                    "projectCount": catalog.projects.count
                ])
            } catch where isCurrentConnection(generation) && selectedTargetID == targetID {
                diagnostics.record("chatCatalog.failed", level: .warning, fields: errorFields(error))
            } catch {
                // The request belongs to a previous connection/target. Its
                // result is irrelevant and must not mutate the current UI.
            }
            if connectionGeneration == generation {
                isLoadingChatCatalog = false
            }
        }
    }

    func startNewThread(initialMessage: String? = nil) {
        guard canSwitchThreads, !isOpeningThread else {
            diagnostics.record("thread.start.skipped", level: .debug, fields: [
                "canSwitchThreads": canSwitchThreads,
                "isOpeningThread": isOpeningThread
            ])
            return
        }
        clearCloudChatMirror()
        let initial = initialMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingNewThreadMessage = (initial?.isEmpty == false) ? initial : nil
        diagnostics.record("thread.start.requested", fields: ["workingDirectory": workingDirectory])
        isOpeningThread = true
        lastError = nil
        var params: [String: Any] = ["ephemeral": false]
        let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty { params["cwd"] = cwd }
        sendRequest(method: "thread/start", params: params, kind: .threadStart)
    }

    func startNewThreadFromDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        startNewThread(initialMessage: text)
    }

    func openThread(_ thread: RemoteThreadSummary) {
        guard canSwitchThreads, !isOpeningThread else {
            diagnostics.record("thread.read.skipped", level: .debug, fields: [
                "threadID": thread.id,
                "canSwitchThreads": canSwitchThreads,
                "isOpeningThread": isOpeningThread
            ])
            return
        }
        diagnostics.record("thread.read.requested", fields: [
            "threadID": thread.id,
            "model": thread.model ?? "",
            "status": thread.status ?? "",
            "source": thread.source ?? "",
            "titleLength": thread.title.count,
            "previewLength": thread.preview.count
        ])
        clearCloudChatMirror()
        isOpeningThread = true
        lastError = nil
        sendRequest(
            method: "thread/read",
            params: ["threadId": thread.id, "includeTurns": false],
            kind: .threadRead(threadID: thread.id, title: thread.title, model: thread.model, preserveMessages: false)
        )
    }

    func openChatCatalogEntry(_ entry: RemoteChatCatalogEntry) {
        guard canSwitchThreads, !isOpeningThread, !isLoadingCloudTranscript else {
            diagnostics.record("chatCatalog.open.skipped", level: .debug, fields: [
                "canOpenRemotely": entry.canOpenRemotely,
                "canSwitchThreads": canSwitchThreads,
                "isOpeningThread": isOpeningThread || isLoadingCloudTranscript,
                "sourceKind": entry.sourceKind
            ])
            return
        }
        diagnostics.record("chatCatalog.open.requested", fields: [
            "sourceKind": entry.sourceKind,
            "hasProject": entry.projectId != nil,
            "titleLength": entry.title.count
        ])
        if !entry.canOpenRemotely {
            openCloudChatMirror(entry)
            return
        }
        clearCloudChatMirror()
        isOpeningThread = true
        lastError = nil
        sendRequest(
            method: "thread/read",
            params: ["threadId": entry.id, "includeTurns": false],
            kind: .threadRead(
                threadID: entry.id,
                title: entry.title,
                model: nil,
                preserveMessages: false
            )
        )
    }

    func refreshActiveCloudChat() {
        guard let entry = activeCloudCatalogEntry, isCloudChatMirror else { return }
        openCloudChatMirror(entry, isRefresh: true)
    }

    private func openCloudChatMirror(_ entry: RemoteChatCatalogEntry, isRefresh: Bool = false) {
        guard entry.sourceKind == "chatgpt", let target = selectedTarget else {
            lastError = "This Desktop conversation is not available for mirroring"
            return
        }
        cloudTranscriptGeneration += 1
        let transcriptGeneration = cloudTranscriptGeneration
        let isSameConversation = activeCloudCatalogEntry?.id == entry.id && isCloudChatMirror
        if !isRefresh {
            if !isSameConversation {
                if let cached = cloudConversationCache[entry.id] {
                    messages = cached.messages
                    cloudChatIsPartial = cached.isPartial
                    cloudRemoteMessageCount = cached.remoteMessageCount
                    diagnostics.record("chatTranscript.cache.hit", fields: [
                        "messageCount": cached.messages.count,
                        "ageSeconds": max(0, Int(Date().timeIntervalSince(cached.savedAt)))
                    ])
                } else {
                    messages = []
                    cloudChatIsPartial = false
                    cloudRemoteMessageCount = 0
                    diagnostics.record("chatTranscript.cache.miss", level: .debug)
                }
                stagedCloudAttachments = []
                isUploadingCloudAttachment = false
                pendingCloudSendRequestID = nil
                pendingCloudSendConversationID = nil
                pendingCloudSendText = nil
                pendingCloudSendAttachmentIDs = []
                pendingCloudSendBaselineMessageCount = 0
                cloudSendRequiresRefresh = false
            }
            activeThreadTitle = entry.title
            activeCloudCatalogEntry = entry
            isCloudChatMirror = true
            cloudChatActivity = "idle"
            threadID = nil
            threadCanAcceptDirectInput = false
            threadHasActiveWriter = false
            nextTurnCursor = nil
            activeAssistantMessageID = nil
            selectedModel = nil
            showingThreadList = false
        }
        isLoadingCloudTranscript = true
        isOpeningThread = false
        lastError = nil
        let expectedTargetID = target.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await hostClient.fetchChatTranscript(
                    target: target,
                    conversationID: entry.id,
                    baseURL: serverURL,
                    token: capabilityToken,
                    allowTrustedOverlayPlaintext: trustedOverlayPlaintext
                )
                guard cloudTranscriptGeneration == transcriptGeneration,
                      selectedTargetID == expectedTargetID
                else {
                    diagnostics.record("chatTranscript.staleResponseDropped", level: .debug, fields: [
                        "targetID": expectedTargetID
                    ])
                    return
                }
                let mirroredMessages: [ChatMessage]
                if let items = transcript.items, !items.isEmpty {
                    mirroredMessages = items.compactMap(mirroredChatMessage(from:))
                } else {
                    mirroredMessages = transcript.messages.compactMap { item -> ChatMessage? in
                        switch item.role {
                        case "user": ChatMessage(role: .user, text: item.text)
                        case "assistant": ChatMessage(role: .assistant, text: item.text)
                        default: nil
                        }
                    }
                }
                messages = mirroredMessages
                cloudRemoteMessageCount = transcript.messageCount
                activeThreadTitle = transcript.title
                activeCloudCatalogEntry = entry
                isCloudChatMirror = true
                cloudChatActivity = transcript.activity
                cloudChatIsPartial = transcript.isPartial
                cloudChatCanSendText = transcript.capabilities?.sendText == true
                cloudChatCanAttach = transcript.capabilities?.attachments == true
                threadID = nil
                threadCanAcceptDirectInput = false
                threadHasActiveWriter = false
                nextTurnCursor = nil
                activeAssistantMessageID = nil
                selectedModel = nil
                showingThreadList = false
                state = .ready
                cloudConversationCache[entry.id] = RemotePresentationSnapshot.CachedCloudConversation(
                    conversationID: entry.id,
                    title: transcript.title,
                    savedAt: Date(),
                    messages: mirroredMessages,
                    isPartial: transcript.isPartial,
                    remoteMessageCount: transcript.messageCount
                ).bounded()
                reconcilePendingCloudSend(after: transcript, refreshed: isRefresh)
                schedulePresentationSnapshotSave()
                diagnostics.record("chatTranscript.applied", fields: [
                    "messageCount": mirroredMessages.count,
                    "activity": transcript.activity,
                    "isPartial": transcript.isPartial,
                    "hasProject": transcript.projectId != nil
                ])
            } catch where cloudTranscriptGeneration == transcriptGeneration && selectedTargetID == expectedTargetID {
                diagnostics.record("chatTranscript.failed", level: .warning, fields: errorFields(error))
                lastError = error.localizedDescription
            } catch {
                // A newer mirror request, disconnect, or target switch owns the UI now.
            }
            if cloudTranscriptGeneration == transcriptGeneration {
                isLoadingCloudTranscript = false
            }
        }
    }

    private func clearCloudChatMirror(invalidateRequests: Bool = true) {
        if invalidateRequests { cloudTranscriptGeneration += 1 }
        isCloudChatMirror = false
        cloudChatActivity = "idle"
        cloudChatIsPartial = false
        cloudChatCanSendText = false
        cloudChatCanAttach = false
        stagedCloudAttachments = []
        isUploadingCloudAttachment = false
        isLoadingCloudTranscript = false
        isSendingCloudMessage = false
        cloudSendRequiresRefresh = false
        cloudRemoteMessageCount = 0
        pendingCloudSendRequestID = nil
        pendingCloudSendConversationID = nil
        pendingCloudSendText = nil
        pendingCloudSendAttachmentIDs = []
        pendingCloudSendBaselineMessageCount = 0
        activeCloudCatalogEntry = nil
    }

    func loadEarlierTurns() {
        guard let threadID, let cursor = nextTurnCursor, !isLoadingEarlierTurns, canSwitchThreads, !showingThreadList else { return }
        isLoadingEarlierTurns = true
        diagnostics.record("thread.turns.earlier.requested", fields: ["threadID": threadID])
        sendRequest(
            method: "thread/turns/list",
            params: ["threadId": threadID, "cursor": cursor, "limit": 20, "sortDirection": "desc", "itemsView": "full"],
            kind: .threadTurnsList(initial: false)
        )
    }

    func showConversations() {
        guard canSwitchThreads else {
            diagnostics.record("thread.browser.open.skipped", level: .debug, fields: ["canSwitchThreads": false])
            return
        }
        diagnostics.record("thread.browser.opened")
        showingThreadList = true
        refreshThreads()
    }

    func selectModel(_ model: RemoteModelOption) {
        guard canSwitchThreads else {
            diagnostics.record("model.selection.skipped", level: .debug, fields: ["model": model.model])
            return
        }
        selectedModel = model.model
        diagnostics.record("model.selected", fields: ["model": model.model, "displayName": model.displayName])
    }
    func modelDisplayName(for model: String) -> String {
        models.first(where: { $0.model == model || $0.id == model })?.displayName ?? model
    }

    func stageCloudAttachment(filename: String, mimeType: String, data: Data) {
        guard canStageCloudAttachment,
              let entry = activeCloudCatalogEntry,
              let target = selectedTarget
        else {
            diagnostics.record("chatAttachment.stage.skipped", level: .debug, fields: [
                "byteCount": data.count,
                "canAttach": cloudChatCanAttach,
                "stagedCount": stagedCloudAttachments.count
            ])
            return
        }
        isUploadingCloudAttachment = true
        lastError = nil
        let expectedTargetID = target.id
        let expectedConversationID = entry.id
        diagnostics.record("chatAttachment.stage.requested", fields: [
            "targetID": expectedTargetID,
            "byteCount": data.count,
            "mimeType": mimeType
        ])
        Task { [weak self] in
            guard let self else { return }
            do {
                let attachment = try await hostClient.uploadChatAttachment(
                    target: target,
                    filename: filename,
                    mimeType: mimeType,
                    data: data,
                    baseURL: serverURL,
                    token: capabilityToken,
                    allowTrustedOverlayPlaintext: trustedOverlayPlaintext
                )
                guard selectedTargetID == expectedTargetID,
                      activeCloudCatalogEntry?.id == expectedConversationID,
                      isCloudChatMirror
                else { return }
                stagedCloudAttachments.append(attachment)
                diagnostics.record("chatAttachment.stage.confirmed", fields: [
                    "targetID": expectedTargetID,
                    "byteCount": attachment.size,
                    "stagedCount": stagedCloudAttachments.count
                ])
            } catch {
                guard selectedTargetID == expectedTargetID,
                      activeCloudCatalogEntry?.id == expectedConversationID,
                      isCloudChatMirror
                else { return }
                diagnostics.record("chatAttachment.stage.failed", level: .warning, fields: errorFields(error))
                lastError = error.localizedDescription
            }
            if selectedTargetID == expectedTargetID,
               activeCloudCatalogEntry?.id == expectedConversationID {
                isUploadingCloudAttachment = false
            }
        }
    }

    func removeCloudAttachment(id: String) {
        stagedCloudAttachments.removeAll { $0.id == id }
        diagnostics.record("chatAttachment.removed", fields: [
            "stagedCount": stagedCloudAttachments.count
        ])
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCloudChatMirror {
            sendCloudChatDraft(text)
            return
        }
        guard !text.isEmpty, let threadID, canSwitchThreads, !showingThreadList else {
            diagnostics.record("turn.send.skipped", level: .debug, fields: [
                "textLength": text.count,
                "hasThreadID": self.threadID != nil,
                "canSwitchThreads": canSwitchThreads,
                "showingThreadList": showingThreadList
            ])
            return
        }
        diagnostics.record("turn.send.requested", fields: [
            "threadID": threadID,
            "textLength": text.count,
            "model": selectedModel ?? "",
            "canAcceptDirectInput": threadCanAcceptDirectInput as Any
        ])
        startTurn(text: text, threadID: threadID)
    }

    private func sendCloudChatDraft(_ text: String) {
        let attachmentIDs = stagedCloudAttachments.map(\.attachmentId)
        guard (!text.isEmpty || !attachmentIDs.isEmpty),
              canSwitchThreads,
              !showingThreadList,
              !isSendingCloudMessage,
              !isUploadingCloudAttachment,
              !cloudSendRequiresRefresh,
              cloudChatActivity != "streaming",
              let entry = activeCloudCatalogEntry,
              let target = selectedTarget
        else {
            diagnostics.record("chatMessage.send.skipped", level: .debug, fields: [
                "textLength": text.count,
                "hasConversation": activeCloudCatalogEntry != nil,
                "isSending": isSendingCloudMessage,
                "isUploadingAttachment": isUploadingCloudAttachment,
                "attachmentCount": attachmentIDs.count,
                "requiresRefresh": cloudSendRequiresRefresh,
                "activity": cloudChatActivity
            ])
            return
        }

        let requestID: String
        if pendingCloudSendConversationID == entry.id,
           pendingCloudSendText == text,
           pendingCloudSendAttachmentIDs == attachmentIDs,
           let pendingCloudSendRequestID {
            requestID = pendingCloudSendRequestID
        } else {
            requestID = UUID().uuidString.lowercased()
            pendingCloudSendRequestID = requestID
            pendingCloudSendConversationID = entry.id
            pendingCloudSendText = text
            pendingCloudSendAttachmentIDs = attachmentIDs
            pendingCloudSendBaselineMessageCount = cloudRemoteMessageCount
        }
        isSendingCloudMessage = true
        lastError = nil
        let expectedTargetID = target.id
        let expectedConversationID = entry.id
        diagnostics.record("chatMessage.send.requested", fields: [
            "targetID": expectedTargetID,
            "textLength": text.count,
            "attachmentCount": attachmentIDs.count,
            "baselineMessageCount": pendingCloudSendBaselineMessageCount
        ])

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await hostClient.sendChatMessage(
                    target: target,
                    conversationID: expectedConversationID,
                    text: text,
                    clientRequestID: requestID,
                    attachmentIDs: attachmentIDs,
                    baseURL: serverURL,
                    token: capabilityToken,
                    allowTrustedOverlayPlaintext: trustedOverlayPlaintext
                )
                guard selectedTargetID == expectedTargetID,
                      activeCloudCatalogEntry?.id == expectedConversationID,
                      isCloudChatMirror
                else { return }
                isSendingCloudMessage = false
                cloudSendRequiresRefresh = false
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                    draft = ""
                }
                pendingCloudSendRequestID = nil
                pendingCloudSendConversationID = nil
                pendingCloudSendText = nil
                pendingCloudSendAttachmentIDs = []
                pendingCloudSendBaselineMessageCount = 0
                stagedCloudAttachments.removeAll { attachmentIDs.contains($0.attachmentId) }
                if !text.isEmpty && (messages.last?.role != .user || messages.last?.text != text) {
                    messages.append(ChatMessage(role: .user, text: text))
                }
                cloudChatActivity = "streaming"
                diagnostics.record("chatMessage.send.confirmed", fields: [
                    "targetID": expectedTargetID
                ])
                openCloudChatMirror(entry, isRefresh: true)
            } catch {
                guard selectedTargetID == expectedTargetID,
                      activeCloudCatalogEntry?.id == expectedConversationID,
                      isCloudChatMirror
                else { return }
                isSendingCloudMessage = false
                let definitelyNotSubmitted: Bool
                if case RemoteHostError.httpStatus(409, _) = error {
                    definitelyNotSubmitted = true
                } else {
                    definitelyNotSubmitted = false
                }
                if case RemoteHostError.httpStatus(409, "chat-attachment-unavailable") = error {
                    stagedCloudAttachments.removeAll { attachmentIDs.contains($0.attachmentId) }
                    pendingCloudSendRequestID = nil
                    pendingCloudSendConversationID = nil
                    pendingCloudSendText = nil
                    pendingCloudSendAttachmentIDs = []
                    pendingCloudSendBaselineMessageCount = 0
                }
                cloudSendRequiresRefresh = !definitelyNotSubmitted
                var fields = errorFields(error)
                fields["targetID"] = expectedTargetID
                fields["requiresRefresh"] = cloudSendRequiresRefresh
                diagnostics.record("chatMessage.send.failed", level: .warning, fields: fields)
                lastError = error.localizedDescription
            }
        }
    }

    private func reconcilePendingCloudSend(after transcript: RemoteChatTranscript, refreshed: Bool) {
        guard let pendingText = pendingCloudSendText,
              let pendingConversationID = pendingCloudSendConversationID,
              pendingConversationID == transcript.conversationId
        else {
            if refreshed { cloudSendRequiresRefresh = false }
            return
        }
        let latestUserText = transcript.messages.last(where: { $0.role == "user" })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewRemoteMessage = transcript.messageCount > pendingCloudSendBaselineMessageCount
        let wasObserved = hasNewRemoteMessage
            && (pendingText.isEmpty ? !pendingCloudSendAttachmentIDs.isEmpty : latestUserText == pendingText)
        if wasObserved {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == pendingText {
                draft = ""
            }
            pendingCloudSendRequestID = nil
            pendingCloudSendConversationID = nil
            pendingCloudSendText = nil
            stagedCloudAttachments.removeAll { pendingCloudSendAttachmentIDs.contains($0.attachmentId) }
            pendingCloudSendAttachmentIDs = []
            pendingCloudSendBaselineMessageCount = 0
            cloudSendRequiresRefresh = false
            diagnostics.record("chatMessage.send.confirmedByRefresh")
        } else if refreshed && cloudSendRequiresRefresh {
            // A successful read-after-uncertain-send did not observe a new user
            // turn, so a manual retry may safely reuse the same request id.
            cloudSendRequiresRefresh = false
            pendingCloudSendBaselineMessageCount = transcript.messageCount
            diagnostics.record("chatMessage.send.retryUnlockedAfterRefresh", level: .debug)
        }
    }

    private func startTurn(text: String, threadID: String) {
        draft = ""
        messages.append(ChatMessage(role: .user, text: text))
        activeAssistantMessageID = nil
        state = .running

        sendTurnRequest(text: text, threadID: threadID, canResumeIfMissing: true)
    }

    private func sendTurnRequest(text: String, threadID: String, canResumeIfMissing: Bool) {
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": text, "text_elements": []]]
        ]
        if let selectedModel { params["model"] = selectedModel }
        sendRequest(
            method: "turn/start",
            params: params,
            kind: .turnStart(text: text, canResumeIfMissing: canResumeIfMissing)
        )
    }

    private func requestThreads(append: Bool) {
        guard codexClient.isActive, isConnected, !isLoadingThreads else {
            diagnostics.record("threads.request.skipped", level: .debug, fields: [
                "append": append,
                "hasSocket": codexClient.isActive,
                "isConnected": isConnected,
                "isLoading": isLoadingThreads
            ])
            return
        }
        if append, nextThreadCursor == nil {
            diagnostics.record("threads.request.skipped", level: .debug, fields: ["append": true, "reason": "noCursor"])
            return
        }
        diagnostics.record("threads.requested", fields: [
            "append": append,
            "hasCursor": nextThreadCursor != nil
        ])
        isLoadingThreads = true
        lastError = nil
        var params: [String: Any] = [
            "archived": false,
            "limit": 50,
            "sortKey": "recency_at",
            "sortDirection": "desc",
            // Request every source kind advertised by the current app-server
            // contract. Plura must not hide Chat/Work/Codex or sub-agent
            // history by guessing semantics from a narrower source allowlist.
            "sourceKinds": [
                "cli", "vscode", "exec", "appServer",
                "subAgent", "subAgentReview", "subAgentCompact",
                "subAgentThreadSpawn", "subAgentOther", "unknown"
            ]
        ]
        if append, let nextThreadCursor { params["cursor"] = nextThreadCursor }
        sendRequest(method: "thread/list", params: params, kind: .threadList(append: append))
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            let sourceID = params["itemId"] as? String ?? params["id"] as? String
            let messageID = ensureLiveAssistantMessage(sourceID: sourceID)
            guard
                  let index = messages.firstIndex(where: { $0.id == messageID }) else {
                diagnostics.record("turn.delta.dropped", level: .warning, fields: [
                    "hasDelta": params["delta"] is String,
                    "hasActiveAssistant": activeAssistantMessageID != nil,
                    "messageCount": messages.count
                ])
                return
            }
            messages[index].text += delta
            diagnostics.record("turn.delta.applied", level: .debug, fields: [
                "deltaLength": delta.count,
                "assistantLength": messages[index].text.count
            ])
        case "item/reasoning/summaryTextDelta":
            guard let delta = params["delta"] as? String, !delta.isEmpty,
                  let itemID = params["itemId"] as? String ?? params["id"] as? String
            else { return }
            if let messageID = liveActivityMessageIDs[itemID],
               let index = messages.firstIndex(where: { $0.id == messageID }) {
                if messages[index].kind == .reasoningSummary,
                   messages[index].text == "Thinking…" {
                    messages[index].text = delta
                } else {
                    messages[index].text += delta
                }
            } else {
                let message = ChatMessage(
                    role: .activity,
                    text: delta,
                    kind: .reasoningSummary,
                    sourceID: itemID,
                    title: "Thinking"
                )
                messages.append(message)
                liveActivityMessageIDs[itemID] = message.id
            }
        case "item/reasoning/summaryPartAdded":
            guard let itemID = params["itemId"] as? String ?? params["id"] as? String,
                  let messageID = liveActivityMessageIDs[itemID],
                  let index = messages.firstIndex(where: { $0.id == messageID }),
                  messages[index].kind == .reasoningSummary,
                  !messages[index].text.isEmpty,
                  messages[index].text != "Thinking…",
                  !messages[index].text.hasSuffix("\n\n")
            else { return }
            messages[index].text += "\n\n"
        case "item/reasoning/textDelta":
            // Raw reasoning content is intentionally not a Plura display surface.
            // Only the app-server's user-visible reasoning summary is rendered.
            diagnostics.record("reasoning.rawDelta.ignored", level: .debug)
        case "turn/completed":
            let finalLength: Int
            if let messageID = activeAssistantMessageID,
               let index = messages.firstIndex(where: { $0.id == messageID }),
               messages[index].text.isEmpty {
                messages[index].text = "(Codex completed without a text response.)"
                finalLength = 0
            } else if let messageID = activeAssistantMessageID,
                      let index = messages.firstIndex(where: { $0.id == messageID }) {
                finalLength = messages[index].text.count
            } else {
                messages.append(ChatMessage(role: .assistant, text: "(Codex completed without a text response.)"))
                finalLength = 0
            }
            diagnostics.record("turn.completed", fields: [
                "threadID": threadID ?? "",
                "assistantLength": finalLength,
                "paramKeys": params.keys.sorted()
            ])
            activeAssistantMessageID = nil
            state = .ready
            schedulePresentationSnapshotSave()
        case "thread/settings/updated":
            guard params["threadId"] as? String == threadID,
                  let settings = params["threadSettings"] as? [String: Any] else {
                diagnostics.record("thread.settings.ignored", level: .debug, fields: [
                    "incomingThreadID": params["threadId"] as? String ?? "",
                    "activeThreadID": threadID ?? ""
                ])
                return
            }
            if let model = settings["model"] as? String {
                selectedModel = model
                diagnostics.record("thread.settings.model.updated", fields: ["model": model])
            }
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agentMessage" {
                let messageID = ensureLiveAssistantMessage(sourceID: item["id"] as? String)
                if let text = item["text"] as? String, !text.isEmpty,
                   let index = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[index].text = text
                }
                return
            }
            guard
                  let message = timelineActivityMessage(
                    from: item,
                    allowReasoningPlaceholder: method == "item/started"
                  )
            else { return }
            let itemID = item["id"] as? String
            if let itemID,
               let messageID = liveActivityMessageIDs[itemID],
               let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index] = message.withID(messageID)
            } else {
                messages.append(message)
                if let itemID { liveActivityMessageIDs[itemID] = message.id }
            }
        case "error":
            let error = params["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Codex reported an error"
            diagnostics.record("protocol.server.error", level: .error, fields: [
                "message": message,
                "errorKeys": error?.keys.sorted() ?? []
            ])
            finishTurnWithError(message)
        default:
            diagnostics.record("protocol.notification.unhandled", level: .debug, fields: ["method": method])
        }
    }

    private func handleServerRequest(id: CodexRequestID, method: String, params: [String: Any]) {
        if method == "currentTime/read" {
            codexClient.sendServerResponse(
                id: id,
                result: ["currentTimeAt": Int(Date().timeIntervalSince1970)]
            )
            diagnostics.record("serverRequest.currentTime.responded")
            return
        }

        if method == "item/tool/requestUserInput" {
            guard let prompt = userInputPrompt(from: params) else {
                codexClient.sendServerError(id: id, code: -32602, message: "Invalid user input request")
                diagnostics.record("userInput.invalid", level: .warning)
                return
            }
            let request = PendingUserInputRequest(id: id, prompt: prompt)
            if !hasActiveInteraction {
                presentUserInput(request)
            } else if queuedInteractionCount >= Self.maxQueuedInteractions {
                codexClient.sendServerError(id: id, code: -32000, message: "Too many pending interactions")
                diagnostics.record("userInput.queueOverflow", level: .warning)
            } else {
                userInputQueue.append(request)
                diagnostics.record("userInput.queued", fields: ["queueDepth": userInputQueue.count])
            }
            return
        }

        if method == "mcpServer/elicitation/request" {
            guard let prompt = RemoteMcpElicitationPrompt(params: params) else {
                codexClient.sendServerResponse(id: id, result: ["action": "decline"])
                diagnostics.record("mcp.elicitation.declined", level: .warning, fields: [
                    "mode": params["mode"] as? String ?? "unknown",
                    "reason": "unsupportedOrInvalid"
                ])
                messages.append(ChatMessage(
                    role: .activity,
                    text: "This elicitation type is not supported by this Plura Mobile client, so it was declined.",
                    kind: .notice,
                    title: "MCP input request",
                    status: "declined"
                ))
                return
            }

            let request = PendingMcpElicitationRequest(id: id, prompt: prompt)
            if !hasActiveInteraction {
                presentMcpElicitation(request)
            } else if queuedInteractionCount >= Self.maxQueuedInteractions {
                codexClient.sendServerError(id: id, code: -32000, message: "Too many pending interactions")
                diagnostics.record("mcp.elicitation.queueOverflow", level: .warning)
            } else {
                mcpElicitationQueue.append(request)
                diagnostics.record("mcp.elicitation.queued", fields: ["queueDepth": mcpElicitationQueue.count])
            }
            return
        }

        let prompt: RemoteApprovalPrompt?
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = RemoteApprovalPrompt(
                kind: .command,
                title: "Allow command?",
                detail: approvalDetail(primary: command, secondary: reason)
            )
        case "item/fileChange/requestApproval", "applyPatchApproval":
            let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let root = (params["grantRoot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = RemoteApprovalPrompt(
                kind: .fileChange,
                title: "Allow file changes?",
                detail: approvalDetail(primary: reason, secondary: root)
            )
        case "item/permissions/requestApproval":
            let reason = (params["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = RemoteApprovalPrompt(
                kind: .permissions,
                title: "Allow additional permissions?",
                detail: approvalDetail(primary: reason, secondary: "The request may include filesystem or network access for this turn.")
            )
        default:
            diagnostics.record("serverRequest.unhandled", level: .warning, fields: ["method": method])
            lastError = "The Mac requested an unsupported approval: \(method)"
            codexClient.sendServerError(id: id, code: -32601, message: "Plura does not support this server request")
            return
        }
        guard let prompt else { return }
        let request = PendingApprovalRequest(id: id, method: method, params: params, prompt: prompt)
        if !hasActiveInteraction {
            presentApproval(request)
        } else if queuedInteractionCount >= Self.maxQueuedInteractions {
            codexClient.sendServerError(id: id, code: -32000, message: "Too many pending interactions")
            diagnostics.record("approval.queueOverflow", level: .warning, fields: ["method": method])
        } else {
            approvalQueue.append(request)
            diagnostics.record("approval.queued", fields: [
                "method": method,
                "queueDepth": approvalQueue.count
            ])
        }
    }

    func respondToApproval(allow: Bool) {
        guard let request = activeApprovalRequest else { return }
        let id = request.id
        let method = request.method
        let params = request.params

        let result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval",
             "item/fileChange/requestApproval", "applyPatchApproval":
            result = ["decision": allow ? "accept" : "decline"]
        case "item/permissions/requestApproval":
            if allow, let permissions = params["permissions"] as? [String: Any] {
                result = ["permissions": permissions, "scope": "turn"]
            } else {
                result = ["permissions": [String: Any](), "scope": "turn"]
            }
        default:
            return
        }

        codexClient.sendServerResponse(id: id, result: result)
        diagnostics.record("approval.responded", fields: ["method": method, "allowed": allow])
        activeApprovalRequest = nil
        approvalPrompt = nil
        presentNextInteractionIfNeeded()
    }

    private func presentApproval(_ request: PendingApprovalRequest) {
        activeApprovalRequest = request
        approvalPrompt = request.prompt
        diagnostics.record("approval.presented", fields: [
            "method": request.method,
            "kind": request.prompt.kind.rawValue,
            "queuedBehind": approvalQueue.count
        ])
    }

    private func presentNextInteractionIfNeeded() {
        guard !hasActiveInteraction else { return }
        if !approvalQueue.isEmpty {
            presentApproval(approvalQueue.removeFirst())
        } else if !userInputQueue.isEmpty {
            presentUserInput(userInputQueue.removeFirst())
        } else if !mcpElicitationQueue.isEmpty {
            presentMcpElicitation(mcpElicitationQueue.removeFirst())
        }
    }

    private var hasActiveInteraction: Bool {
        activeApprovalRequest != nil || activeUserInputRequest != nil || activeMcpElicitationRequest != nil
    }

    private var queuedInteractionCount: Int {
        approvalQueue.count + userInputQueue.count + mcpElicitationQueue.count
    }

    private func userInputPrompt(from params: [String: Any]) -> RemoteUserInputPrompt? {
        guard let rawQuestions = params["questions"] as? [[String: Any]], !rawQuestions.isEmpty else { return nil }
        let questions = rawQuestions.compactMap { question -> RemoteUserInputPrompt.Question? in
            guard let id = question["id"] as? String,
                  let header = question["header"] as? String,
                  let text = question["question"] as? String
            else { return nil }
            let options = (question["options"] as? [[String: Any]] ?? []).compactMap { option -> RemoteUserInputPrompt.Option? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String
                else { return nil }
                return .init(label: label, description: description)
            }
            guard Set(options.map(\.label)).count == options.count else { return nil }
            return .init(
                id: id,
                header: header,
                question: text,
                options: options,
                isOther: question["isOther"] as? Bool ?? false,
                isSecret: question["isSecret"] as? Bool ?? false
            )
        }
        guard questions.count == rawQuestions.count,
              Set(questions.map(\.id)).count == questions.count
        else { return nil }
        return RemoteUserInputPrompt(questions: questions)
    }

    private func presentUserInput(_ request: PendingUserInputRequest) {
        activeUserInputRequest = request
        userInputPrompt = request.prompt
        diagnostics.record("userInput.presented", fields: [
            "questionCount": request.prompt.questions.count,
            "queuedBehind": userInputQueue.count
        ])
    }

    func respondToUserInput(answers: [String: [String]], cancelled: Bool = false) {
        guard let request = activeUserInputRequest else { return }
        let payload: [String: Any] = cancelled
            ? ["answers": [String: Any]()]
            : ["answers": answers.mapValues { ["answers": $0] }]
        codexClient.sendServerResponse(id: request.id, result: payload)
        diagnostics.record("userInput.responded", fields: [
            "cancelled": cancelled,
            "answerCount": answers.count
        ])
        activeUserInputRequest = nil
        userInputPrompt = nil
        presentNextInteractionIfNeeded()
    }

    private func presentMcpElicitation(_ request: PendingMcpElicitationRequest) {
        activeMcpElicitationRequest = request
        mcpElicitationPrompt = request.prompt
        diagnostics.record("mcp.elicitation.presented", fields: [
            "serverName": request.prompt.serverName,
            "fieldCount": request.prompt.fields.count,
            "queuedBehind": mcpElicitationQueue.count
        ])
    }

    func respondToMcpElicitation(values: [String: RemoteMcpElicitationValue], cancelled: Bool = false) {
        guard let request = activeMcpElicitationRequest else { return }
        let result: [String: Any]
        if cancelled {
            result = ["action": "cancel"]
        } else {
            result = [
                "action": "accept",
                "content": values.mapValues(\.jsonValue)
            ]
        }
        codexClient.sendServerResponse(id: request.id, result: result)
        diagnostics.record("mcp.elicitation.responded", fields: [
            "cancelled": cancelled,
            "valueCount": values.count
        ])
        activeMcpElicitationRequest = nil
        mcpElicitationPrompt = nil
        presentNextInteractionIfNeeded()
    }

    private func approvalDetail(primary: String?, secondary: String?) -> String {
        let values = [primary, secondary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        let joined = values.joined(separator: "\n\n")
        if joined.count <= 600 { return joined.isEmpty ? "Review this action on your Mac profile." : joined }
        let index = joined.index(joined.startIndex, offsetBy: 600)
        return String(joined[..<index]) + "…"
    }

    private func handleResponse(id: Int, object: [String: Any]) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            diagnostics.record("request.response.unmatched", level: .warning, fields: ["id": id])
            return
        }
        let elapsed = pending.sentAt.duration(to: ContinuousClock.now)
        diagnostics.record("request.completed", fields: [
            "id": id,
            "method": pending.method,
            "kind": pending.kind.diagnosticsName,
            "durationMs": durationMilliseconds(elapsed),
            "hasError": object["error"] != nil
        ])
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Request failed"
            diagnostics.record("request.failed", level: .error, fields: [
                "id": id,
                "method": pending.method,
                "kind": pending.kind.diagnosticsName,
                "message": message,
                "errorKeys": error.keys.sorted()
            ])
            handleRequestError(kind: pending.kind, message: message)
            return
        }
        guard let result = object["result"] as? [String: Any] else {
            diagnostics.record("request.result.invalid", level: .error, fields: [
                "id": id,
                "method": pending.method,
                "resultType": String(describing: type(of: object["result"] as Any))
            ])
            handleRequestError(kind: pending.kind, message: "Codex returned an invalid response")
            return
        }

        switch pending.kind {
        case .initialize:
            codexClient.sendNotification(method: "initialized")
            persistPairingIfNeeded()
            state = .ready
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectAttempt = 0
            diagnostics.record("connection.initialized", fields: ["resultKeys": result.keys.sorted()])
            refreshModels()
            refreshThreads()
            refreshChatCatalog()
            if preservePresentationOnNextConnect,
               isCloudChatMirror,
               let activeCloudCatalogEntry
            {
                showingThreadList = false
                openCloudChatMirror(activeCloudCatalogEntry, isRefresh: true)
            } else if preservePresentationOnNextConnect,
               !showingThreadList,
               let threadID
            {
                sendRequest(
                    method: "thread/read",
                    params: ["threadId": threadID, "includeTurns": false],
                    kind: .threadRead(
                        threadID: threadID,
                        title: activeThreadTitle ?? "Conversation",
                        model: selectedModel,
                        preserveMessages: true
                    )
                )
            } else {
                showingThreadList = true
            }
            preservePresentationOnNextConnect = false
        case .threadList(let append):
            isLoadingThreads = false
            let rawPage = result["data"] as? [[String: Any]] ?? []
            let parsedPage = rawPage.compactMap(RemoteThreadSummary.init(object:))
            let page = parsedPage.filter { $0.parentThreadID == nil }
            if append {
                var known = Set(threads.map(\.id))
                threads.append(contentsOf: page.filter { known.insert($0.id).inserted })
            } else { threads = page }
            nextThreadCursor = result["nextCursor"] as? String
            diagnostics.record("threads.loaded", fields: [
                "append": append,
                "rawCount": rawPage.count,
                "parsedCount": parsedPage.count,
                "totalCount": threads.count,
                "droppedCount": rawPage.count - parsedPage.count,
                "childThreadCount": parsedPage.count - page.count,
                "hasNextCursor": nextThreadCursor != nil
            ])
            schedulePresentationSnapshotSave()
        case .modelList:
            isLoadingModels = false
            let rawModels = result["data"] as? [[String: Any]] ?? []
            models = rawModels.compactMap(RemoteModelOption.init(object:))
            diagnostics.record("models.loaded", fields: [
                "rawCount": rawModels.count,
                "parsedCount": models.count,
                "droppedCount": rawModels.count - models.count,
                "models": models.map(\.model)
            ])
            schedulePresentationSnapshotSave()
        case .threadStart:
            isOpeningThread = false
            threadHasActiveWriter = true
            openThreadResponse(result, fallbackTitle: "New Conversation", fallbackModel: nil)
            if let text = pendingNewThreadMessage, let threadID {
                pendingNewThreadMessage = nil
                startTurn(text: text, threadID: threadID)
            } else {
                pendingNewThreadMessage = nil
            }
        case .threadRead(_, let title, let model, let preserveMessages):
            threadHasActiveWriter = false
            guard preparePagedThread(
                result,
                fallbackTitle: title,
                fallbackModel: model,
                preserveMessages: preserveMessages
            ), let threadID else {
                isOpeningThread = false
                return
            }
            sendRequest(
                method: "thread/turns/list",
                params: ["threadId": threadID, "limit": 20, "sortDirection": "desc", "itemsView": "full"],
                kind: .threadTurnsList(initial: true)
            )
        case .threadTurnsList(let initial):
            let rawTurns = result["data"] as? [[String: Any]] ?? []
            let pageMessages = messages(fromTurns: rawTurns.reversed())
            nextTurnCursor = result["nextCursor"] as? String
            if initial {
                messages = pageMessages
                isOpeningThread = false
                showingThreadList = false
            } else {
                messages = pageMessages + messages
                isLoadingEarlierTurns = false
            }
            diagnostics.record("thread.turns.loaded", fields: [
                "initial": initial,
                "turnCount": rawTurns.count,
                "messageCount": pageMessages.count,
                "hasNextCursor": nextTurnCursor != nil
            ])
            schedulePresentationSnapshotSave()
        case .threadResumeForSend(let text):
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
                diagnostics.record("thread.resumeForSend.invalidResponse", level: .error, fields: [
                    "resultKeys": result.keys.sorted()
                ])
                state = .ready
                lastError = "Codex returned no thread identifier while preparing to send"
                return
            }
            threadID = id
            threadCanAcceptDirectInput = thread["canAcceptDirectInput"] as? Bool
            threadHasActiveWriter = true
            diagnostics.record("thread.resumeForSend.completed", fields: [
                "threadID": id,
                "canAcceptDirectInput": threadCanAcceptDirectInput as Any,
                "hasActiveWriter": threadHasActiveWriter
            ])
            guard threadCanAcceptDirectInput != false else {
                state = .ready
                lastError = "This conversation is not accepting direct input"
                return
            }
            sendTurnRequest(text: text, threadID: id, canResumeIfMissing: false)
        case .turnStart:
            break
        }
    }

    private func openThreadResponse(_ result: [String: Any], fallbackTitle: String, fallbackModel: String?) {
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
            diagnostics.record("thread.open.invalidResponse", level: .error, fields: [
                "resultKeys": result.keys.sorted(),
                "threadKeys": (result["thread"] as? [String: Any])?.keys.sorted() ?? []
            ])
            lastError = "Codex returned no thread identifier"
            showingThreadList = true
            return
        }
        threadID = id
        threadCanAcceptDirectInput = thread["canAcceptDirectInput"] as? Bool
        activeThreadTitle = threadTitle(from: thread) ?? fallbackTitle
        selectedModel = thread["model"] as? String ?? fallbackModel
        messages = messages(from: thread)
        showingThreadList = false
        state = .ready
        diagnostics.record("thread.opened", fields: [
            "threadID": id,
            "model": selectedModel ?? "",
            "turnCount": (thread["turns"] as? [[String: Any]])?.count ?? 0,
            "messageCount": messages.count,
            "canAcceptDirectInput": threadCanAcceptDirectInput as Any,
            "threadKeys": thread.keys.sorted()
        ])
        schedulePresentationSnapshotSave()
    }

    @discardableResult
    private func preparePagedThread(
        _ result: [String: Any],
        fallbackTitle: String,
        fallbackModel: String?,
        preserveMessages: Bool
    ) -> Bool {
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else {
            diagnostics.record("thread.read.invalidResponse", level: .error, fields: ["resultKeys": result.keys.sorted()])
            lastError = "Codex returned no thread identifier"
            showingThreadList = true
            return false
        }
        threadID = id
        threadCanAcceptDirectInput = thread["canAcceptDirectInput"] as? Bool
        activeThreadTitle = threadTitle(from: thread) ?? fallbackTitle
        selectedModel = thread["model"] as? String ?? fallbackModel
        if !preserveMessages { messages = [] }
        nextTurnCursor = nil
        state = .ready
        return true
    }

    private func messages(from thread: [String: Any]) -> [ChatMessage] {
        guard let turns = thread["turns"] as? [[String: Any]] else { return [] }
        return messages(fromTurns: turns)
    }

    private func messages<S: Sequence>(fromTurns turns: S) -> [ChatMessage] where S.Element == [String: Any] {
        var output: [ChatMessage] = []
        for turn in turns {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "userMessage":
                    let text = (item["content"] as? [[String: Any]] ?? []).compactMap { input -> String? in
                        guard input["type"] as? String == "text" else { return nil }
                        return input["text"] as? String
                    }.joined(separator: "\n")
                    if !text.isEmpty { output.append(ChatMessage(role: .user, text: text)) }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        output.append(ChatMessage(role: .assistant, text: text))
                    }
                default:
                    if let message = timelineActivityMessage(from: item) {
                        output.append(message)
                    }
                }
            }
        }
        return output
    }

    private func mirroredChatMessage(from item: RemoteChatTimelineItem) -> ChatMessage? {
        let kind = ChatMessage.Kind(rawValue: item.kind) ?? .unknown
        if kind == .message {
            switch item.role {
            case "user":
                return ChatMessage(
                    role: .user,
                    text: item.text,
                    kind: kind,
                    sourceID: item.sourceId
                )
            case "assistant":
                return ChatMessage(
                    role: .assistant,
                    text: item.text,
                    kind: kind,
                    sourceID: item.sourceId
                )
            default:
                return nil
            }
        }

        let title = item.title ?? semanticTitle(for: kind)
        let detail = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatMessage(
            role: .activity,
            text: detail,
            kind: kind,
            sourceID: item.sourceId,
            title: title,
            status: item.status,
            durationMilliseconds: item.durationMs
        )
    }

    private func ensureLiveAssistantMessage(sourceID: String?) -> UUID {
        if let messageID = activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            if messages[index].sourceID == nil, let sourceID {
                messages[index].sourceID = sourceID
            }
            return messageID
        }
        let message = ChatMessage(
            role: .assistant,
            text: "",
            kind: .message,
            sourceID: sourceID
        )
        messages.append(message)
        activeAssistantMessageID = message.id
        return message.id
    }

    private func semanticTitle(for kind: ChatMessage.Kind) -> String {
        switch kind {
        case .message: "Message"
        case .reasoningSummary: "Thinking"
        case .toolCall: "Tool"
        case .commandExecution: "Command"
        case .fileChange: "File changes"
        case .webSearch: "Web search"
        case .imageView: "Image viewed"
        case .approval: "Approval"
        case .attachment: "Attachment"
        case .notice: "Activity"
        case .unknown: "Activity"
        }
    }

    private func timelineActivityMessage(
        from item: [String: Any],
        allowReasoningPlaceholder: Bool = false
    ) -> ChatMessage? {
        let status = scalarDescription(item["status"])
        let durationMs = integerValue(item["durationMs"])
        let sourceID = item["id"] as? String
        let kind: ChatMessage.Kind
        let title: String
        let detail: String?
        switch item["type"] as? String {
        case "commandExecution":
            kind = .commandExecution
            title = "Command"
            detail = clipped(item["command"] as? String, limit: 320)
        case "fileChange":
            let count = (item["changes"] as? [[String: Any]])?.count ?? 0
            kind = .fileChange
            title = "File changes"
            detail = count > 0 ? "\(count) change(s)" : nil
        case "mcpToolCall":
            let server = clipped(item["server"] as? String, limit: 80)
            let tool = clipped(item["tool"] as? String, limit: 120)
            let name = [server, tool].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            kind = .toolCall
            title = "Tool"
            detail = name
        case "dynamicToolCall":
            let namespace = clipped(item["namespace"] as? String, limit: 80)
            let tool = clipped(item["tool"] as? String, limit: 120)
            let name = [namespace, tool].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            kind = .toolCall
            title = "Tool"
            detail = name
        case "collabAgentToolCall":
            kind = .toolCall
            title = "Agent"
            detail = clipped(item["tool"] as? String, limit: 120)
        case "webSearch":
            kind = .webSearch
            title = "Web search"
            detail = clipped(item["query"] as? String, limit: 240)
        case "imageView":
            kind = .imageView
            title = "Image viewed"
            detail = nil
        case "reasoning":
            kind = .reasoningSummary
            title = "Thinking"
            let summary = reasoningSummary(from: item)
            if let summary, !summary.isEmpty {
                detail = summary
            } else if allowReasoningPlaceholder {
                return ChatMessage(
                    role: .activity,
                    text: "Thinking…",
                    kind: kind,
                    sourceID: sourceID,
                    title: title,
                    status: status,
                    durationMilliseconds: durationMs
                )
            } else {
                detail = nil
            }
        default:
            guard let type = clipped(item["type"] as? String, limit: 120),
                  !["userMessage", "agentMessage"].contains(type)
            else { return nil }
            kind = .unknown
            title = "Activity"
            // Preserve the existence/order of new protocol item kinds without
            // guessing that arbitrary payload fields are safe user-visible text.
            detail = type
        }
        return ChatMessage(
            role: .activity,
            text: detail ?? "",
            kind: kind,
            sourceID: sourceID,
            title: title,
            status: status,
            durationMilliseconds: durationMs
        )
    }

    private func reasoningSummary(from item: [String: Any]) -> String? {
        if let summary = item["summary"] as? [String] {
            let parts = summary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : clipped(parts.joined(separator: "\n\n"), limit: 8_000)
        }
        if let summary = item["summary"] as? String {
            return clipped(summary, limit: 8_000)
        }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func scalarDescription(_ value: Any?) -> String? {
        if let value = value as? String { return clipped(value, limit: 80) }
        if let value = value as? NSNumber { return value.stringValue }
        if let value = value as? [String: Any], let type = value["type"] as? String { return clipped(type, limit: 80) }
        return nil
    }

    private func clipped(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return trimmed }
        let index = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<index]) + "…"
    }

    private func threadTitle(from thread: [String: Any]) -> String? {
        if let name = thread["name"] as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let preview = thread["preview"] as? String {
            let first = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func handleRequestError(kind: RequestKind, message: String) {
        diagnostics.record("request.error.applied", level: .error, fields: [
            "kind": kind.diagnosticsName,
            "message": message
        ])
        switch kind {
        case .initialize: state = .failed(message)
        case .threadList: isLoadingThreads = false; lastError = message
        case .modelList: isLoadingModels = false; lastError = message
        case .threadStart:
            isOpeningThread = false
            if let pendingNewThreadMessage, draft.isEmpty {
                draft = pendingNewThreadMessage
            }
            pendingNewThreadMessage = nil
            lastError = message
        case .threadRead(let threadID, _, _, _):
            isOpeningThread = false
            diagnostics.record("thread.read.failed", level: .error, fields: [
                "threadID": threadID,
                "message": message
            ])
            lastError = message
        case .threadTurnsList(let initial):
            if initial { isOpeningThread = false } else { isLoadingEarlierTurns = false }
            lastError = message
        case .threadResumeForSend:
            state = .ready
            lastError = message
        case .turnStart(let text, let canResumeIfMissing):
            if canResumeIfMissing, message.hasPrefix("thread not found:") {
                guard let threadID else {
                    finishTurnWithError(message)
                    return
                }
                diagnostics.record("thread.resumeForSend.requested", fields: [
                    "threadID": threadID,
                    "textLength": text.count,
                    "priorCanAcceptDirectInput": threadCanAcceptDirectInput as Any,
                    "reason": "turnStartThreadNotFound"
                ])
                state = .running
                sendRequest(
                    method: "thread/resume",
                    params: ["threadId": threadID, "excludeTurns": true],
                    kind: .threadResumeForSend(text: text)
                )
            } else {
                finishTurnWithError(message)
            }
        }
    }

    @discardableResult
    private func sendRequest(method: String, params: [String: Any], kind: RequestKind) -> Int {
        let id = allocateRequestID()
        pendingRequests[id] = PendingRequest(kind: kind, method: method, sentAt: ContinuousClock.now)
        diagnostics.record("request.started", fields: [
            "id": id,
            "method": method,
            "kind": kind.diagnosticsName,
            "pendingCount": pendingRequests.count,
            "paramKeys": params.keys.sorted(),
            "threadID": params["threadId"] as? String ?? "",
            "model": params["model"] as? String ?? "",
            "inputTextLength": inputTextLength(params)
        ])
        codexClient.sendRequest(id: id, method: method, params: params)
        return id
    }

    private func finishTurnWithError(_ message: String) {
        diagnostics.record("turn.failed", level: .error, fields: [
            "threadID": threadID ?? "",
            "message": message
        ])
        if let messageID = activeAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            let existing = messages[index].text
            messages[index].text = existing.isEmpty ? "Codex error: \(message)" : existing + "\n\nCodex error: \(message)"
        } else {
            messages.append(ChatMessage(role: .assistant, text: "Codex error: \(message)"))
        }
        activeAssistantMessageID = nil
        state = .ready
        schedulePresentationSnapshotSave()
    }

    private func allocateRequestID() -> Int { defer { nextRequestID += 1 }; return nextRequestID }

    private func disconnect(
        resetState: Bool,
        reason: String,
        preservePresentation: Bool,
        invalidateConnectionAttempt: Bool
    ) {
        if invalidateConnectionAttempt {
            connectionGeneration += 1
            connectTask?.cancel()
            connectTask = nil
        }
        diagnostics.record("connection.disconnect", fields: [
            "reason": reason,
            "resetState": resetState,
            "hadSocket": codexClient.isActive,
            "taskID": codexClient.taskID,
            "pendingRequestCount": pendingRequests.count,
            "threadID": threadID ?? ""
        ])
        codexClient.disconnect(reason: reason)
        approvalPrompt = nil
        activeApprovalRequest = nil
        approvalQueue.removeAll()
        userInputPrompt = nil
        activeUserInputRequest = nil
        userInputQueue.removeAll()
        mcpElicitationPrompt = nil
        activeMcpElicitationRequest = nil
        mcpElicitationQueue.removeAll()
        liveActivityMessageIDs.removeAll()
        activeAssistantMessageID = nil
        pendingRequests.removeAll(); nextThreadCursor = nil; nextTurnCursor = nil
        cloudTranscriptGeneration += 1
        isLoadingThreads = false; isLoadingChatCatalog = false; isLoadingCloudTranscript = false
        isLoadingModels = false; isOpeningThread = false; isLoadingEarlierTurns = false
        if preservePresentation {
            threadHasActiveWriter = false
        } else {
            clearCloudChatMirror(invalidateRequests: false)
            cloudConversationCache = [:]
            threadID = nil; threadCanAcceptDirectInput = nil; threadHasActiveWriter = false; activeThreadTitle = nil
            threads = []; chatCatalogEntries = []; chatProjects = []; hasLoadedChatCatalog = false
            models = []; messages = []; selectedModel = nil
            showingThreadList = true
        }
        lastError = nil
        if resetState { state = .disconnected }
    }

    private func handleTransportFailure(_ error: Error, generation: Int) {
        guard isCurrentConnection(generation) else {
            diagnostics.record("connection.transport.staleFailureIgnored", level: .debug, fields: [
                "generation": generation,
                "currentGeneration": connectionGeneration
            ])
            return
        }
        diagnostics.record("connection.transport.failed", level: .error, fields: errorFields(error))
        state = .failed(error.localizedDescription)
        scheduleReconnect(reason: "transport.failed")
    }

    private func isCurrentConnection(_ generation: Int) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    private func persistPairingIfNeeded() {
        let token = capabilityToken.trimmingCharacters(in: .whitespacesAndNewlines)
        serverURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try RemoteCredentialStore.saveToken(token)
            try RemoteCredentialStore.saveServerURL(serverURL)
            if let selectedTargetID {
                try RemoteCredentialStore.saveTargetID(selectedTargetID)
            }
            try RemoteCredentialStore.saveEndpoints(connectionEndpoints)
            capabilityToken = token
            hasSavedPairing = true
            diagnostics.record("pairing.keychain.saved")
        } catch {
            diagnostics.record("pairing.keychain.saveFailed", level: .error, fields: [
                "error": String(describing: error)
            ])
        }
    }

    private func stateName(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .ready: "ready"
        case .running: "running"
        case .failed: "failed"
        }
    }

    private var stateIsReadyOrRunning: Bool {
        switch state {
        case .ready, .running:
            true
        case .disconnected, .connecting, .failed:
            false
        }
    }

    private func inputTextLength(_ params: [String: Any]) -> Int {
        guard let input = params["input"] as? [[String: Any]] else { return 0 }
        return input.reduce(into: 0) { total, item in
            if let text = item["text"] as? String { total += text.count }
        }
    }

    private func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private func errorFields(_ error: Error) -> [String: Any] {
        let value = error as NSError
        return [
            "domain": value.domain,
            "code": value.code,
            "description": value.localizedDescription
        ]
    }
}
