import Foundation

struct RemotePresentationSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let maximumTargets = 16
    static let maximumThreadsPerTarget = 250
    static let maximumChatEntriesPerTarget = 750
    static let maximumProjectsPerTarget = 250
    static let maximumMessagesPerTarget = 500
    static let maximumCloudConversationsPerTarget = 32
    static let maximumModelsPerTarget = 64

    struct CachedCloudConversation: Codable, Equatable {
        let conversationID: String
        let title: String
        let savedAt: Date
        let messages: [ChatMessage]
        let isPartial: Bool
        let remoteMessageCount: Int

        func bounded() -> CachedCloudConversation {
            CachedCloudConversation(
                conversationID: conversationID,
                title: title,
                savedAt: savedAt,
                messages: Array(messages.suffix(RemotePresentationSnapshot.maximumMessagesPerTarget)),
                isPartial: isPartial,
                remoteMessageCount: max(0, remoteMessageCount)
            )
        }
    }

    struct TargetPresentation: Codable, Equatable {
        let targetID: String
        let savedAt: Date
        let threads: [RemoteThreadSummary]
        let chatCatalogEntries: [RemoteChatCatalogEntry]
        let chatProjects: [RemoteChatProject]
        let hasLoadedChatCatalog: Bool
        let models: [RemoteModelOption]
        let selectedModel: String?
        let showingThreadList: Bool
        let threadID: String?
        let activeThreadTitle: String?
        let messages: [ChatMessage]
        let isCloudChatMirror: Bool
        let activeCloudConversationID: String?
        let cloudChatIsPartial: Bool
        let cloudRemoteMessageCount: Int
        let cloudConversationCache: [String: CachedCloudConversation]?

        func bounded() -> TargetPresentation {
            let boundedCachePairs = (cloudConversationCache ?? [:])
                .values
                .sorted { $0.savedAt > $1.savedAt }
                .prefix(RemotePresentationSnapshot.maximumCloudConversationsPerTarget)
                .map { ($0.conversationID, $0.bounded()) }
            return TargetPresentation(
                targetID: targetID,
                savedAt: savedAt,
                threads: Array(threads.prefix(RemotePresentationSnapshot.maximumThreadsPerTarget)),
                chatCatalogEntries: Array(chatCatalogEntries.prefix(RemotePresentationSnapshot.maximumChatEntriesPerTarget)),
                chatProjects: Array(chatProjects.prefix(RemotePresentationSnapshot.maximumProjectsPerTarget)),
                hasLoadedChatCatalog: hasLoadedChatCatalog,
                models: Array(models.prefix(RemotePresentationSnapshot.maximumModelsPerTarget)),
                selectedModel: selectedModel,
                showingThreadList: showingThreadList,
                threadID: threadID,
                activeThreadTitle: activeThreadTitle,
                messages: Array(messages.suffix(RemotePresentationSnapshot.maximumMessagesPerTarget)),
                isCloudChatMirror: isCloudChatMirror,
                activeCloudConversationID: activeCloudConversationID,
                cloudChatIsPartial: cloudChatIsPartial,
                cloudRemoteMessageCount: max(0, cloudRemoteMessageCount),
                cloudConversationCache: Dictionary(uniqueKeysWithValues: boundedCachePairs)
            )
        }
    }

    let version: Int
    let savedAt: Date
    let selectedTargetID: String?
    let targets: [RemoteTarget]
    let presentations: [String: TargetPresentation]

    func bounded() -> RemotePresentationSnapshot {
        let keptTargets = Array(targets.prefix(Self.maximumTargets))
        let keptIDs = Set(keptTargets.map(\.id))
        let boundedPresentations: [String: TargetPresentation] = Dictionary(
            uniqueKeysWithValues: presentations.compactMap { element -> (String, TargetPresentation)? in
                let (key, value) = element
                guard keptIDs.contains(key) else { return nil }
                return (key, value.bounded())
            }
        )
        return RemotePresentationSnapshot(
            version: Self.currentVersion,
            savedAt: savedAt,
            selectedTargetID: selectedTargetID.flatMap { keptIDs.contains($0) ? $0 : nil },
            targets: keptTargets,
            presentations: boundedPresentations
        )
    }
}

struct RemotePresentationSnapshotStore: Sendable {
    static let maximumSnapshotBytes = 8 * 1024 * 1024

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        let manager = FileManager.default
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ChatGPT Plura", isDirectory: true)
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("presentation-snapshot-v1.json")
    }

    func load() -> RemotePresentationSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0,
              size <= Self.maximumSnapshotBytes,
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let snapshot = try? JSONDecoder().decode(RemotePresentationSnapshot.self, from: data),
              snapshot.version == RemotePresentationSnapshot.currentVersion
        else { return nil }
        return snapshot.bounded()
    }

    func save(_ snapshot: RemotePresentationSnapshot) throws {
        let bounded = snapshot.bounded()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(bounded)
        guard data.count <= Self.maximumSnapshotBytes else {
            throw SnapshotError.tooLarge
        }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }

    func delete() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return }
        try manager.removeItem(at: fileURL)
    }

    enum SnapshotError: Error {
        case tooLarge
    }
}
