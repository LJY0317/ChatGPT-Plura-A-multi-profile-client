import XCTest
@testable import ChatGPT_Plura___A_multi_profile_client

final class RemoteEndpointPolicyTests: XCTestCase {
    func testTargetDiscoveryTimeoutAllowsCanonicalDesktopRefreshLatency() {
        XCTAssertEqual(RemoteHostClient.targetDiscoveryTimeout, 10)
    }

#if DEBUG
    func testLaunchAutomationUsesEnvironmentFallback() {
        let configuration = RemoteLaunchAutomationConfiguration(
            arguments: ["Plura Mobile"],
            environment: [
                "PLURA_REMOTE_CONNECT_ON_LAUNCH": "1",
                "PLURA_REMOTE_SERVER_URL": "ws://100.64.0.1:8766",
                "PLURA_REMOTE_TARGET_ID": "target-2",
                "PLURA_REMOTE_PAIRING_BOOTSTRAP_FILE": "bootstrap.txt"
            ]
        )

        XCTAssertTrue(configuration.requested)
        XCTAssertEqual(configuration.serverURL, "ws://100.64.0.1:8766")
        XCTAssertEqual(configuration.targetID, "target-2")
        XCTAssertEqual(configuration.bootstrapFilename, "bootstrap.txt")
    }

    func testLaunchAutomationArgumentsOverrideEnvironmentFallback() {
        let configuration = RemoteLaunchAutomationConfiguration(
            arguments: [
                "Plura Mobile",
                "--remote-connect-on-launch",
                "--remote-server-url", "ws://127.0.0.1:8767",
                "--remote-target-id", "argument-target",
                "--remote-pairing-bootstrap-file", "argument-bootstrap.txt"
            ],
            environment: [
                "PLURA_REMOTE_CONNECT_ON_LAUNCH": "1",
                "PLURA_REMOTE_SERVER_URL": "ws://environment:8766",
                "PLURA_REMOTE_TARGET_ID": "environment-target",
                "PLURA_REMOTE_PAIRING_BOOTSTRAP_FILE": "environment-bootstrap.txt"
            ]
        )

        XCTAssertTrue(configuration.requested)
        XCTAssertEqual(configuration.serverURL, "ws://127.0.0.1:8767")
        XCTAssertEqual(configuration.targetID, "argument-target")
        XCTAssertEqual(configuration.bootstrapFilename, "argument-bootstrap.txt")
    }
#endif

    func testPresentationSnapshotPersistsBoundedOfflineState() throws {
        let target = try JSONDecoder().decode(
            RemoteTarget.self,
            from: Data(#"{"id":"profile-2","displayName":"ChatGPT Profile 2","role":"managed","route":"/targets/profile-2/ws","activationState":"ready","chatMirrorState":"ready"}"#.utf8)
        )
        let chatEntry = try JSONDecoder().decode(
            RemoteChatCatalogEntry.self,
            from: Data(#"{"id":"chat-1","title":"Cached chat","updatedAt":1700000000,"sourceKind":"chatgpt","projectId":"project-1","projectName":"Project","isPinned":true,"canOpenRemotely":true}"#.utf8)
        )
        let project = try JSONDecoder().decode(
            RemoteChatProject.self,
            from: Data(#"{"id":"project-1","name":"Project","isPinned":true,"sortOrder":0}"#.utf8)
        )
        let thread = try XCTUnwrap(RemoteThreadSummary(object: [
            "id": "thread-1",
            "preview": "Cached work",
            "updatedAt": NSNumber(value: 1_700_000_001)
        ]))
        let model = try XCTUnwrap(RemoteModelOption(object: [
            "id": "model-1",
            "model": "gpt-test",
            "displayName": "GPT Test"
        ]))
        let presentation = RemotePresentationSnapshot.TargetPresentation(
            targetID: target.id,
            savedAt: Date(timeIntervalSince1970: 1_700_000_100),
            threads: [thread],
            chatCatalogEntries: [chatEntry],
            chatProjects: [project],
            hasLoadedChatCatalog: true,
            models: [model],
            selectedModel: model.model,
            showingThreadList: false,
            threadID: nil,
            activeThreadTitle: chatEntry.title,
            messages: [ChatMessage(role: .assistant, text: "cached response")],
            isCloudChatMirror: true,
            activeCloudConversationID: chatEntry.id,
            cloudChatIsPartial: false,
            cloudRemoteMessageCount: 1,
            cloudConversationCache: [
                chatEntry.id: RemotePresentationSnapshot.CachedCloudConversation(
                    conversationID: chatEntry.id,
                    title: chatEntry.title,
                    savedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    messages: [ChatMessage(role: .assistant, text: "cached response")],
                    isPartial: false,
                    remoteMessageCount: 1
                )
            ]
        )
        let snapshot = RemotePresentationSnapshot(
            version: RemotePresentationSnapshot.currentVersion,
            savedAt: presentation.savedAt,
            selectedTargetID: target.id,
            targets: [target],
            presentations: [target.id: presentation]
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plura-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemotePresentationSnapshotStore(fileURL: root.appendingPathComponent("snapshot.json"))

        try store.save(snapshot)
        let restored = try XCTUnwrap(store.load())

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.presentations[target.id]?.messages.first?.text, "cached response")
        XCTAssertEqual(restored.presentations[target.id]?.activeCloudConversationID, chatEntry.id)
        XCTAssertEqual(
            restored.presentations[target.id]?.cloudConversationCache?[chatEntry.id]?.messages.first?.text,
            "cached response"
        )
    }

    func testOfflineEmptyPresentationDoesNotReplaceUsefulCache() {
        let cached = RemotePresentationSnapshot.TargetPresentation(
            targetID: "profile-2",
            savedAt: Date(timeIntervalSince1970: 100),
            threads: [],
            chatCatalogEntries: [],
            chatProjects: [],
            hasLoadedChatCatalog: false,
            models: [],
            selectedModel: nil,
            showingThreadList: false,
            threadID: "thread-1",
            activeThreadTitle: "Cached",
            messages: [ChatMessage(role: .assistant, text: "cached")],
            isCloudChatMirror: false,
            activeCloudConversationID: nil,
            cloudChatIsPartial: false,
            cloudRemoteMessageCount: 0,
            cloudConversationCache: [:]
        )
        let empty = RemotePresentationSnapshot.TargetPresentation(
            targetID: "profile-2",
            savedAt: Date(timeIntervalSince1970: 200),
            threads: [],
            chatCatalogEntries: [],
            chatProjects: [],
            hasLoadedChatCatalog: false,
            models: [],
            selectedModel: nil,
            showingThreadList: true,
            threadID: nil,
            activeThreadTitle: nil,
            messages: [],
            isCloudChatMirror: false,
            activeCloudConversationID: nil,
            cloudChatIsPartial: false,
            cloudRemoteMessageCount: 0,
            cloudConversationCache: [:]
        )

        XCTAssertFalse(
            RemotePresentationSnapshot.shouldReplacePresentation(
                existing: cached,
                with: empty,
                whileConnected: false
            )
        )
        XCTAssertTrue(
            RemotePresentationSnapshot.shouldReplacePresentation(
                existing: cached,
                with: empty,
                whileConnected: true
            )
        )
        XCTAssertTrue(
            RemotePresentationSnapshot.shouldReplacePresentation(
                existing: nil,
                with: empty,
                whileConnected: false
            )
        )
    }

    func testChatTranscriptDecodesOptionalSemanticTimelineItems() throws {
        let data = Data(#"""
        {
          "contractVersion":1,
          "conversationId":"conversation",
          "title":"Project chat",
          "projectId":"project",
          "projectName":"Project",
          "source":"desktop-renderer",
          "messages":[{"role":"user","text":"hello","segments":["hello"]}],
          "items":[
            {"kind":"message","role":"user","text":"hello","segments":["hello"]},
            {"kind":"futureCard","text":"visible fallback","title":"Future activity","status":"done","durationMs":1250}
          ],
          "capabilities":{"sendText":true,"attachments":false},
          "activity":"idle",
          "isPartial":false,
          "messageCount":1
        }
        """#.utf8)

        let transcript = try JSONDecoder().decode(RemoteChatTranscript.self, from: data)

        XCTAssertEqual(transcript.items?.count, 2)
        XCTAssertEqual(transcript.items?.first?.kind, "message")
        XCTAssertEqual(transcript.items?.last?.kind, "futureCard")
        XCTAssertEqual(transcript.items?.last?.durationMs, 1_250)
        XCTAssertEqual(transcript.capabilities?.sendText, true)
        XCTAssertEqual(transcript.capabilities?.attachments, false)
    }

    func testChatTranscriptKeepsMessagesWhenSemanticItemsAreAbsent() throws {
        let data = Data(#"""
        {
          "contractVersion":1,
          "conversationId":"conversation",
          "title":"Project chat",
          "projectId":null,
          "projectName":null,
          "source":"desktop-renderer",
          "messages":[{"role":"assistant","text":"hello","segments":["hello"]}],
          "activity":"idle",
          "isPartial":false,
          "messageCount":1
        }
        """#.utf8)

        let transcript = try JSONDecoder().decode(RemoteChatTranscript.self, from: data)

        XCTAssertNil(transcript.items)
        XCTAssertEqual(transcript.messages.first?.text, "hello")
    }

    func testChatSendResultDecodesConfirmedRendererSubmission() throws {
        let data = Data(#"{"contractVersion":1,"conversationId":"conversation","clientRequestId":"request-1","status":"submitted","source":"desktop-renderer"}"#.utf8)

        let result = try JSONDecoder().decode(RemoteChatSendResult.self, from: data)

        XCTAssertEqual(result.conversationId, "conversation")
        XCTAssertEqual(result.clientRequestId, "request-1")
        XCTAssertEqual(result.status, "submitted")
        XCTAssertEqual(result.source, "desktop-renderer")
    }

    func testChatAttachmentDecodesStagedFileMetadata() throws {
        let data = Data(#"{"attachmentId":"opaque_attachment_1234","filename":"photo.png","mimeType":"image/png","size":4096}"#.utf8)

        let attachment = try JSONDecoder().decode(RemoteChatAttachment.self, from: data)

        XCTAssertEqual(attachment.id, "opaque_attachment_1234")
        XCTAssertEqual(attachment.filename, "photo.png")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.size, 4_096)
    }

    func testChatWriteErrorsExplainDraftProtectionAndUncertainSubmit() {
        XCTAssertTrue(
            RemoteHostError.httpStatus(409, "desktop-composer-draft-present")
                .localizedDescription.contains("unsent draft")
        )
        XCTAssertTrue(
            RemoteHostError.httpStatus(503, "chat-send-uncertain")
                .localizedDescription.contains("Refresh")
        )
        XCTAssertTrue(
            RemoteHostError.httpStatus(409, "desktop-attachment-draft-present")
                .localizedDescription.contains("unsent attachment")
        )
        XCTAssertTrue(
            RemoteHostError.httpStatus(503, "desktop-attachment-upload-timeout")
                .localizedDescription.contains("attachment")
        )
    }

    func testDefaultTargetUsesProfileOnePresentationName() throws {
        let data = Data(#"{"id":"default","displayName":"ChatGPT","role":"default","route":"/targets/default/ws","activationState":"restart-required","chatMirrorState":"restart-required"}"#.utf8)
        let target = try JSONDecoder().decode(RemoteTarget.self, from: data)

        XCTAssertTrue(target.isPrimaryTarget)
        XCTAssertEqual(target.presentationName, "ChatGPT Profile 1")
        XCTAssertEqual(target.presentationName(targetCount: 1), "ChatGPT")
        XCTAssertEqual(target.presentationName(targetCount: 2), "ChatGPT Profile 1")
        XCTAssertEqual(target.menuTitle, "ChatGPT Profile 1 · Restart Required")
    }

    func testManagedTargetKeepsUpstreamDisplayName() throws {
        let data = Data(#"{"id":"local.example.profile2","displayName":"ChatGPT Profile 2","role":"managed","route":"/targets/profile2/ws","activationState":"ready","chatMirrorState":"ready"}"#.utf8)
        let target = try JSONDecoder().decode(RemoteTarget.self, from: data)

        XCTAssertFalse(target.isPrimaryTarget)
        XCTAssertEqual(target.presentationName, "ChatGPT Profile 2")
        XCTAssertEqual(target.presentationName(targetCount: 1), "ChatGPT Profile 2")
        XCTAssertEqual(target.menuTitle, "ChatGPT Profile 2")
    }

    func testReadyTargetSurfacesRendererRelaunchCapabilitySeparately() throws {
        let data = Data(#"{"id":"default","displayName":"ChatGPT","role":"default","route":"/targets/default/ws","activationState":"ready","chatMirrorState":"restart-required"}"#.utf8)
        let target = try JSONDecoder().decode(RemoteTarget.self, from: data)

        XCTAssertEqual(target.presentationName, "ChatGPT Profile 1")
        XCTAssertEqual(target.activationState, .ready)
        XCTAssertEqual(target.chatMirrorState, .restartRequired)
        XCTAssertTrue(target.chatMirrorNeedsRelaunch)
        XCTAssertTrue(target.menuTitle.contains("Chat relaunch recommended"))
    }

    func testAllowsPrivateOverlayPlaintextHosts() throws {
        let allowed = [
            "ws://127.0.0.1:8765",
            "ws://10.20.30.40:8765",
            "ws://172.16.0.1:8765",
            "ws://172.31.255.254:8765",
            "ws://192.168.50.42:8765",
            "ws://169.254.4.3:8765",
            "ws://100.64.0.1:8765",
            "ws://100.127.255.254:8765",
            "ws://[fd7a:115c:a1e0::1234]:8765",
            "ws://my-mac.local:8765",
            "ws://mac.home.arpa:8765",
            "ws://mac.tail1234.ts.net:8765"
        ]

        for value in allowed {
            XCTAssertNoThrow(try RemoteEndpointPolicy.validatedComponents(value), value)
        }
    }

    func testRejectsPublicPlaintextHosts() {
        let rejected = [
            "ws://example.com:8765",
            "ws://8.8.8.8:8765",
            "ws://172.15.1.1:8765",
            "ws://172.32.1.1:8765",
            "ws://100.63.255.255:8765",
            "ws://100.128.0.1:8765"
        ]

        for value in rejected {
            XCTAssertThrowsError(try RemoteEndpointPolicy.validatedComponents(value), value) { error in
                guard case RemoteHostError.insecurePlaintextHost = error else {
                    return XCTFail("unexpected error for \(value): \(error)")
                }
            }
        }
    }

    func testAllowsTlsForPublicHosts() throws {
        XCTAssertNoThrow(try RemoteEndpointPolicy.validatedComponents("wss://example.com:443"))
    }

    func testAllowsAuthenticatedAdvertisedOverlayHostnameWhenExplicitlyTrusted() throws {
        XCTAssertThrowsError(try RemoteEndpointPolicy.validatedComponents("ws://plura.custom-vpn.example:8765"))
        XCTAssertNoThrow(
            try RemoteEndpointPolicy.validatedComponents(
                "ws://plura.custom-vpn.example:8765",
                allowTrustedOverlayPlaintext: true
            )
        )
    }

    func testRejectsNonWebSocketSchemes() {
        XCTAssertThrowsError(try RemoteEndpointPolicy.validatedComponents("https://example.com"))
        XCTAssertThrowsError(try RemoteEndpointPolicy.validatedComponents("ftp://192.168.0.2"))
    }
}
