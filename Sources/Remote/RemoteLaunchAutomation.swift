import Foundation

#if DEBUG
struct RemoteLaunchAutomationConfiguration: Equatable {
    let requested: Bool
    let targetID: String?
    let serverURL: String?
    let bootstrapFilename: String?

    init(arguments: [String], environment: [String: String]) {
        requested = arguments.contains("--remote-connect-on-launch")
            || environment["PLURA_REMOTE_CONNECT_ON_LAUNCH"] == "1"
        targetID = Self.argumentValue("--remote-target-id", in: arguments)
            ?? environment["PLURA_REMOTE_TARGET_ID"]
        serverURL = Self.argumentValue("--remote-server-url", in: arguments)
            ?? environment["PLURA_REMOTE_SERVER_URL"]
        bootstrapFilename = Self.argumentValue("--remote-pairing-bootstrap-file", in: arguments)
            ?? environment["PLURA_REMOTE_PAIRING_BOOTSTRAP_FILE"]
    }

    private static func argumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}
#endif

extension RemoteCodexStore {
    func runLaunchAutomationIfRequested() async {
#if DEBUG
        let configuration = RemoteLaunchAutomationConfiguration(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        guard configuration.requested else { return }

        if let targetID = configuration.targetID, !targetID.isEmpty {
            selectedTargetID = targetID
        }
        if let url = configuration.serverURL, !url.isEmpty {
            serverURL = url
        }

        if capabilityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !(await bootstrapPairingIfRequested(filename: configuration.bootstrapFilename)) {
            diagnostics.record("launchAutomation.remoteConnect.aborted", level: .warning, fields: [
                "reason": "pairingUnavailable"
            ])
            return
        }

        diagnostics.record("launchAutomation.remoteConnect", fields: [
            "targetID": selectedTargetID ?? "",
            "serverURL": serverURL
        ])
        await connectAsync()
#endif
    }

#if DEBUG
    private func bootstrapPairingIfRequested(filename: String?) async -> Bool {
        guard let filename, !filename.isEmpty
        else { return false }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documents.appendingPathComponent(filename).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == documents.standardizedFileURL else {
            diagnostics.record("launchAutomation.bootstrapPairing.rejected", level: .warning, fields: [
                "reason": "invalidFilename"
            ])
            return false
        }

        defer {
            do {
                try FileManager.default.removeItem(at: fileURL)
                diagnostics.record("launchAutomation.bootstrapFile.removed", level: .debug)
            } catch {
                diagnostics.record("launchAutomation.bootstrapFile.removeFailed", level: .warning, fields: [
                    "error": String(describing: error)
                ])
            }
        }

        do {
            let bootstrapToken = try String(contentsOf: fileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bootstrapToken.isEmpty else {
                diagnostics.record("launchAutomation.bootstrapPairing.rejected", level: .warning, fields: [
                    "reason": "emptyBootstrap"
                ])
                return false
            }

            let result = try await hostClient.bootstrapPairing(
                baseURL: serverURL,
                bootstrapToken: bootstrapToken
            )
            try RemoteCredentialStore.saveToken(result.capabilityToken)
            try RemoteCredentialStore.saveEndpoints(result.endpoints)
            capabilityToken = result.capabilityToken
            connectionEndpoints = result.endpoints
            hasSavedPairing = true
            diagnostics.record("launchAutomation.bootstrapPairing.succeeded")
            return true
        } catch {
            diagnostics.record("launchAutomation.bootstrapPairing.failed", level: .error, fields: [
                "error": String(describing: error)
            ])
            return false
        }
    }

#endif
}
