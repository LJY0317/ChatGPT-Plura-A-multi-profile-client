import Foundation

struct RemoteConnectionEndpoint: Codable, Equatable, Identifiable, Sendable {
    let kind: String
    let label: String
    let url: String
    let priority: Int

    var id: String { url }
}

struct RemotePairingResult: Decodable {
    let contractVersion: Int
    let capabilityToken: String
    let endpoints: [RemoteConnectionEndpoint]
}

private struct RemoteConnectionInfo: Decodable {
    let contractVersion: Int
    let endpoints: [RemoteConnectionEndpoint]
}

private struct RemoteProbeResponse: Decodable {
    let contractVersion: Int
}

struct RemoteChatCatalogEntry: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let updatedAt: Double
    let sourceKind: String
    let projectId: String?
    let projectName: String?
    let isPinned: Bool
    let canOpenRemotely: Bool

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }
}

struct RemoteChatProject: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let isPinned: Bool
    let sortOrder: Int?
}

struct RemoteChatCatalog: Equatable, Codable, Sendable {
    let contractVersion: Int
    let entries: [RemoteChatCatalogEntry]
    let projects: [RemoteChatProject]
}

struct RemoteChatTranscriptMessage: Equatable, Decodable {
    let role: String
    let text: String
    let segments: [String]
}

struct RemoteChatTimelineItem: Equatable, Decodable {
    let kind: String
    let role: String?
    let text: String
    let segments: [String]?
    let sourceId: String?
    let title: String?
    let status: String?
    let durationMs: Int?
}

struct RemoteChatCapabilities: Equatable, Decodable {
    let sendText: Bool
    let attachments: Bool
}

struct RemoteChatAttachment: Equatable, Decodable, Identifiable {
    let attachmentId: String
    let filename: String
    let mimeType: String
    let size: Int

    var id: String { attachmentId }
}

struct RemoteChatTranscript: Equatable, Decodable {
    let contractVersion: Int
    let conversationId: String
    let title: String
    let projectId: String?
    let projectName: String?
    let source: String
    let messages: [RemoteChatTranscriptMessage]
    let items: [RemoteChatTimelineItem]?
    let capabilities: RemoteChatCapabilities?
    let activity: String
    let isPartial: Bool
    let messageCount: Int
}

private struct RemoteChatSendRequest: Encodable {
    let contractVersion: Int
    let clientRequestId: String
    let text: String
    let attachmentIds: [String]
}

struct RemoteChatSendResult: Equatable, Decodable {
    let contractVersion: Int
    let conversationId: String
    let clientRequestId: String
    let status: String
    let source: String
}

struct RemoteTarget: Identifiable, Equatable, Codable, Sendable {
    enum ActivationState: String, Codable, Sendable {
        case ready
        case available
        case restartRequired = "restart-required"
        case unsupported
        case unavailable
    }

    let id: String
    let displayName: String
    let role: String
    let route: String
    let activationState: ActivationState
    let chatMirrorState: ActivationState

    var isPrimaryTarget: Bool {
        role == "default"
    }

    var presentationName: String {
        isPrimaryTarget ? "ChatGPT Profile 1" : displayName
    }

    func presentationName(targetCount: Int) -> String {
        targetCount > 1 ? presentationName : displayName
    }

    var menuTitle: String {
        if activationState != .ready {
            return "\(presentationName) · \(activationShortLabel)"
        }
        if chatMirrorState == .restartRequired {
            return "\(presentationName) · Chat relaunch recommended"
        }
        return presentationName
    }

    var chatMirrorNeedsRelaunch: Bool { chatMirrorState == .restartRequired }
    var chatMirrorIsReady: Bool { chatMirrorState == .ready }

    var activationDescription: String {
        switch activationState {
        case .ready: "Ready for Plura Mobile"
        case .available: "Ready to start through Plura Desktop"
        case .restartRequired: "Quit this target normally once, then launch it again through Plura Desktop"
        case .unsupported: "Canonical Plura Desktop runtime is not supported for this target"
        case .unavailable: "Target is currently unavailable"
        }
    }

    var activationSystemImage: String {
        switch activationState {
        case .ready: "checkmark.circle"
        case .available: "play.circle"
        case .restartRequired: "arrow.clockwise.circle"
        case .unsupported: "nosign"
        case .unavailable: "exclamationmark.circle"
        }
    }

    private var activationShortLabel: String {
        switch activationState {
        case .ready: "Ready"
        case .available: "Available"
        case .restartRequired: "Restart Required"
        case .unsupported: "Unsupported"
        case .unavailable: "Unavailable"
        }
    }
}

struct RemoteReconnectPolicy {
    static func canUseCachedTarget(
        _ target: RemoteTarget?,
        hasSavedPairing: Bool,
        forceTargetDiscovery: Bool
    ) -> Bool {
        guard hasSavedPairing, !forceTargetDiscovery, let target else { return false }
        return target.activationState == .ready && !target.route.isEmpty
    }

    static func shouldAutomaticallyReconnect(_ target: RemoteTarget?) -> Bool {
        guard let target else { return true }
        switch target.activationState {
        case .restartRequired, .unsupported:
            return false
        case .ready, .available, .unavailable:
            return true
        }
    }
}

private struct RemoteTargetsResponse: Decodable {
    let contractVersion: Int
    let targets: [RemoteTarget]
}

private struct RemoteActivationError: Decodable {
    let error: String
}

enum RemoteHostError: LocalizedError, Sendable {
    case invalidBaseURL
    case insecurePlaintextHost
    case unsupportedContract
    case httpStatus(Int, String?)
    case missingPairingToken
    case invalidPairingResponse

    var shouldSurfaceAfterEndpointRace: Bool {
        switch self {
        case .missingPairingToken, .unsupportedContract, .insecurePlaintextHost:
            true
        case .httpStatus(let status, _):
            status == 401 || status == 403
        case .invalidBaseURL, .invalidPairingResponse:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Invalid Plura Host URL"
        case .insecurePlaintextHost: "Plain ws:// is allowed only for local or private-overlay hosts. Use wss:// for public hosts."
        case .unsupportedContract: "The Mac uses an unsupported Plura target contract"
        case .httpStatus(409, let reason):
            switch reason {
            case "chat-relaunch-required": "This profile needs one normal ChatGPT quit and relaunch before Plura Mobile can use its fastest Chat mirror."
            case "chat-mirror-unavailable": "This profile could not prepare a fast Chat mirror right now."
            case "chat-prepare-invalid": "Plura Host rejected an invalid Chat preparation request."
            case "renderer-cdp-restart-required": "This profile is already running without Plura Mobile's fast Chat renderer. Quit that ChatGPT profile normally once, then retry in Plura Mobile; Work remains usable in the meantime."
            case "restart-required": "This target is running outside the canonical Plura Desktop runtime. Quit it normally once, then launch it again."
            case "unsupported": "This target does not support the canonical Plura Desktop runtime on this Mac."
            case "unavailable": "This target is currently unavailable."
            case "target-not-ready": "This ChatGPT Desktop profile is not ready on your Mac."
            case "conversation-row-unavailable": "Open this Project in ChatGPT on your Mac so the conversation appears in its sidebar, then try again."
            case "conversation-row-not-actionable": "ChatGPT Desktop exposed this conversation but did not allow it to be selected."
            case "desktop-renderer-unavailable": "This ChatGPT Desktop session was not launched with the renderer connection required to send Chat messages. Quit this profile normally once, then relaunch it through Plura Desktop."
            case "desktop-renderer-ambiguous": "ChatGPT Desktop exposed more than one writable renderer. Close duplicate ChatGPT windows and try again."
            case "desktop-composer-unavailable": "ChatGPT Desktop did not expose a writable message composer for this conversation."
            case "desktop-composer-draft-present": "ChatGPT Desktop already has an unsent draft. Send or clear that draft on the desktop before sending from Plura Mobile."
            case "desktop-attachment-draft-present": "ChatGPT Desktop already has an unsent attachment. Send or clear it on the desktop before attaching from Plura Mobile."
            case "desktop-conversation-busy": "ChatGPT Desktop is not ready to accept another message yet."
            case "desktop-composer-changed", "conversation-changed-before-submit": "The Desktop conversation or draft changed before Plura Mobile could safely send. Nothing was retried automatically."
            case "desktop-composer-send-unavailable": "ChatGPT Desktop did not expose a safe Send control for this conversation."
            case "desktop-attachment-input-unavailable": "ChatGPT Desktop did not expose a compatible file input for this attachment."
            case "desktop-attachment-input-ambiguous": "ChatGPT Desktop exposed multiple compatible file inputs, so Plura Mobile refused to guess which one to use."
            case "desktop-attachment-changed": "The Desktop attachment selection changed before Plura Mobile could safely send."
            case "chat-attachment-unavailable": "A staged attachment expired or is no longer available. Attach it again before sending."
            case "client-request-id-conflict": "This send request no longer matches the original message. Refresh the conversation before trying again."
            default: "The target is not ready for Remote access."
            }
        case .httpStatus(503, let reason):
            switch reason {
            case "host-unreachable": "Your Mac is not reachable on any saved private-network path right now."
            case "desktop-renderer-unavailable": "ChatGPT Desktop's renderer connection is not available right now."
            case "desktop-renderer-timeout": "ChatGPT Desktop's renderer took too long to respond."
            case "desktop-renderer-failed": "ChatGPT Desktop's renderer could not expose this conversation right now."
            case "desktop-transcript-unavailable": "ChatGPT Desktop did not expose any rendered messages for this conversation."
            case "desktop-renderer-output-too-large": "This Desktop conversation is too large to mirror safely in one request."
            case "chat-send-uncertain": "The Mac could not confirm whether ChatGPT accepted the message. Refresh this conversation before trying again."
            case "chat-write-unavailable": "This Mac host does not currently support sending Desktop Chat messages."
            case "desktop-attachment-upload-timeout": "ChatGPT Desktop did not finish preparing the attachment in time. Refresh the conversation before retrying."
            default: "The Mac could not read this Desktop conversation right now."
            }
        case .httpStatus(413, _): "That attachment is too large for Plura Mobile's staging limit."
        case .httpStatus(400, let reason):
            switch reason {
            case "chat-attachment-invalid": "That file could not be staged safely."
            default: "The Mac rejected this Chat request as invalid."
            }
        case .httpStatus(let status, _): "Plura Host returned HTTP \(status)"
        case .missingPairingToken: "Enter the pairing token shown by the Mac host"
        case .invalidPairingResponse: "The Mac returned an invalid pairing credential"
        }
    }
}

struct RemoteHostClient: Sendable {
    static let targetDiscoveryTimeout: TimeInterval = 10

    private let diagnostics: RemoteDiagnostics

    init(diagnostics: RemoteDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    func fetchTargets(
        baseURL: String,
        token: String,
        timeout: TimeInterval = RemoteHostClient.targetDiscoveryTimeout,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws -> [RemoteTarget] {
        let url = try httpURL(
            baseURL: baseURL,
            path: "/targets",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RemoteTargetsResponse.self, from: data)
        guard decoded.contractVersion == 1 else { throw RemoteHostError.unsupportedContract }
        var seen = Set<String>()
        let targets = decoded.targets.filter { !$0.id.isEmpty && !$0.displayName.isEmpty && !$0.route.isEmpty }
        guard targets.allSatisfy({ seen.insert($0.id).inserted }) else {
            throw RemoteHostError.unsupportedContract
        }
        diagnostics.record("targets.loaded", fields: [
            "count": targets.count,
            "states": Dictionary(grouping: targets, by: { $0.activationState.rawValue }).mapValues(\.count)
        ])
        return targets
    }

    func fetchConnectionInfo(
        baseURL: String,
        token: String,
        timeout: TimeInterval = 4,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws -> [RemoteConnectionEndpoint] {
        let url = try httpURL(
            baseURL: baseURL,
            path: "/connection-info",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RemoteConnectionInfo.self, from: data)
        guard decoded.contractVersion == 1 else { throw RemoteHostError.unsupportedContract }
        return decoded.endpoints.sorted { $0.priority < $1.priority }
    }

    func probeHost(
        baseURL: String,
        token: String,
        timeout: TimeInterval = 2.5,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws {
        let url = try httpURL(
            baseURL: baseURL,
            path: "/ping",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RemoteProbeResponse.self, from: data)
        guard decoded.contractVersion == 1 else { throw RemoteHostError.unsupportedContract }
    }

    func fetchChatCatalog(
        target: RemoteTarget,
        baseURL: String,
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws -> RemoteChatCatalog {
        let routeRoot = target.route.replacingOccurrences(of: "/ws", with: "")
        let url = try httpURL(
            baseURL: baseURL,
            path: routeRoot + "/chat-catalog",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RemoteChatCatalog.self, from: data)
        guard decoded.contractVersion == 1,
              Set(decoded.entries.map(\.id)).count == decoded.entries.count,
              Set(decoded.projects.map(\.id)).count == decoded.projects.count
        else { throw RemoteHostError.unsupportedContract }
        diagnostics.record("chatCatalog.loaded", fields: [
            "entryCount": decoded.entries.count,
            "projectCount": decoded.projects.count,
            "remotelyOpenableCount": decoded.entries.filter(\.canOpenRemotely).count
        ])
        return decoded
    }

    func fetchChatTranscript(
        target: RemoteTarget,
        conversationID: String,
        baseURL: String,
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws -> RemoteChatTranscript {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "-._~"))
        guard let encodedID = conversationID.addingPercentEncoding(withAllowedCharacters: allowed),
              !encodedID.isEmpty
        else { throw RemoteHostError.unsupportedContract }
        let routeRoot = target.route.replacingOccurrences(of: "/ws", with: "")
        let url = try httpURL(
            baseURL: baseURL,
            path: routeRoot + "/chat-conversations/" + encodedID,
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RemoteChatTranscript.self, from: data)
        guard decoded.contractVersion == 1,
              decoded.conversationId == conversationID,
              decoded.source == "desktop-renderer",
              decoded.messageCount == decoded.messages.count,
              ["idle", "streaming"].contains(decoded.activity),
              decoded.messages.allSatisfy({ ["user", "assistant"].contains($0.role) }),
              decoded.items?.allSatisfy({ item in
                  guard !item.kind.isEmpty else { return false }
                  guard let role = item.role else { return true }
                  return ["user", "assistant", "activity"].contains(role)
              }) != false
        else { throw RemoteHostError.unsupportedContract }
        diagnostics.record("chatTranscript.loaded", fields: [
            "messageCount": decoded.messages.count,
            "activity": decoded.activity,
            "isPartial": decoded.isPartial,
            "hasProject": decoded.projectId != nil
        ])
        return decoded
    }

    func uploadChatAttachment(
        target: RemoteTarget,
        filename: String,
        mimeType: String,
        data: Data,
        baseURL: String,
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws -> RemoteChatAttachment {
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else {
            throw RemoteHostError.httpStatus(413, "chat-attachment-too-large")
        }
        var headerCharacters = CharacterSet.alphanumerics
        headerCharacters.formUnion(CharacterSet(charactersIn: "-._~"))
        guard let encodedFilename = filename.addingPercentEncoding(withAllowedCharacters: headerCharacters),
              !encodedFilename.isEmpty,
              !mimeType.isEmpty,
              !mimeType.contains("\r"),
              !mimeType.contains("\n")
        else { throw RemoteHostError.httpStatus(400, "chat-attachment-invalid") }

        let routeRoot = target.route.replacingOccurrences(of: "/ws", with: "")
        let url = try httpURL(
            baseURL: baseURL,
            path: routeRoot + "/chat-attachments",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(encodedFilename, forHTTPHeaderField: "X-Plura-Filename")
        request.httpBody = data
        let (responseData, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: responseData)
        let decoded = try JSONDecoder().decode(RemoteChatAttachment.self, from: responseData)
        guard !decoded.attachmentId.isEmpty,
              !decoded.filename.isEmpty,
              decoded.size == data.count,
              decoded.size > 0
        else { throw RemoteHostError.unsupportedContract }
        diagnostics.record("chatAttachment.staged", fields: [
            "targetID": target.id,
            "byteCount": decoded.size,
            "mimeType": decoded.mimeType
        ])
        return decoded
    }

    func sendChatMessage(
        target: RemoteTarget,
        conversationID: String,
        text: String,
        clientRequestID: String,
        attachmentIDs: [String] = [],
        baseURL: String,
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws -> RemoteChatSendResult {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "-._~"))
        guard let encodedID = conversationID.addingPercentEncoding(withAllowedCharacters: allowed),
              !encodedID.isEmpty,
              !clientRequestID.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RemoteHostError.unsupportedContract }
        let routeRoot = target.route.replacingOccurrences(of: "/ws", with: "")
        let url = try httpURL(
            baseURL: baseURL,
            path: routeRoot + "/chat-conversations/" + encodedID + "/messages",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RemoteChatSendRequest(
            contractVersion: 1,
            clientRequestId: clientRequestID,
            text: text,
            attachmentIds: attachmentIDs
        ))
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RemoteChatSendResult.self, from: data)
        guard decoded.contractVersion == 1,
              decoded.conversationId == conversationID,
              decoded.clientRequestId == clientRequestID,
              decoded.status == "submitted",
              decoded.source == "desktop-renderer"
        else { throw RemoteHostError.unsupportedContract }
        diagnostics.record("chatMessage.sent", fields: [
            "targetID": target.id,
            "textLength": text.count,
            "attachmentCount": attachmentIDs.count
        ])
        return decoded
    }

    func activate(
        target: RemoteTarget,
        baseURL: String,
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws {
        guard target.activationState != .ready else { return }
        guard target.activationState == .available else {
            throw RemoteHostError.httpStatus(409, target.activationState.rawValue)
        }
        let routeRoot = target.route.replacingOccurrences(of: "/ws", with: "")
        let url = try httpURL(
            baseURL: baseURL,
            path: routeRoot + "/activate",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        diagnostics.record("target.activated", fields: ["targetID": target.id])
    }

    func prepareChat(
        target: RemoteTarget,
        allowRelaunch: Bool,
        baseURL: String,
        token: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) async throws {
        let routeRoot = target.route.replacingOccurrences(of: "/ws", with: "")
        let url = try httpURL(
            baseURL: baseURL,
            path: routeRoot + "/chat-prepare",
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "allowRelaunch": allowRelaunch
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try normalizedToken(token))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        diagnostics.record("target.chatPrepared", fields: [
            "targetID": target.id,
            "allowRelaunch": allowRelaunch
        ])
    }

    func webSocketURL(
        baseURL: String,
        target: RemoteTarget,
        allowTrustedOverlayPlaintext: Bool = false
    ) throws -> URL {
        var components = try RemoteEndpointPolicy.validatedComponents(
            baseURL,
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        components.path = target.route
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RemoteHostError.invalidBaseURL }
        return url
    }

    func bootstrapPairing(baseURL: String, bootstrapToken: String) async throws -> RemotePairingResult {
        let url = try httpURL(baseURL: baseURL, path: "/pair")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(bootstrapToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await ephemeralSession().data(for: request)
        try validate(response: response, data: data)
        let result = try JSONDecoder().decode(RemotePairingResult.self, from: data)
        guard result.contractVersion == 2,
              !result.capabilityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw RemoteHostError.invalidPairingResponse }
        return result
    }

    private func normalizedToken(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RemoteHostError.missingPairingToken }
        return value
    }

    private func httpURL(
        baseURL: String,
        path: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) throws -> URL {
        var components = try RemoteEndpointPolicy.validatedComponents(
            baseURL,
            allowTrustedOverlayPlaintext: allowTrustedOverlayPlaintext
        )
        switch components.scheme {
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: throw RemoteHostError.invalidBaseURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw RemoteHostError.invalidBaseURL }
        return url
    }

    private func normalizedBaseURL(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteHostError.invalidBaseURL }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? JSONDecoder().decode(RemoteActivationError.self, from: data))?.error
            throw RemoteHostError.httpStatus(http.statusCode, reason)
        }
    }
}

enum RemoteEndpointPolicy {
    static func validatedComponents(
        _ baseURL: String,
        allowTrustedOverlayPlaintext: Bool = false
    ) throws -> URLComponents {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "ws" || scheme == "wss",
              !host.isEmpty
        else { throw RemoteHostError.invalidBaseURL }

        if scheme == "ws",
           !allowTrustedOverlayPlaintext,
           !allowsPlaintextPrivateTransport(host: host)
        {
            throw RemoteHostError.insecurePlaintextHost
        }
        return components
    }

    static func allowsPlaintextPrivateTransport(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".home.arpa") || host.hasSuffix(".ts.net") { return true }
        if let octets = ipv4Octets(host) {
            let (a, b) = (octets[0], octets[1])
            if a == 10 || a == 127 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 192 && b == 168 { return true }
            if a == 169 && b == 254 { return true }
            if a == 100 && (64...127).contains(b) { return true }
            return false
        }
        if host.contains(":") {
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") { return true }
        }
        return false
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return values
    }
}
