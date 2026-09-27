import Foundation

extension RemoteCodexStore {
    func runLaunchAutomationIfRequested() async {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--remote-connect-on-launch") else { return }

        if let targetID = launchArgumentValue("--remote-target-id", in: arguments), !targetID.isEmpty {
            selectedTargetID = targetID
        }
        if let url = launchArgumentValue("--remote-server-url", in: arguments), !url.isEmpty {
            serverURL = url
        }

        if capabilityToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !(await bootstrapPairingIfRequested(arguments)) {
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
    private func bootstrapPairingIfRequested(_ arguments: [String]) async -> Bool {
        guard let filename = launchArgumentValue("--remote-pairing-bootstrap-file", in: arguments),
              !filename.isEmpty
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

    private func launchArgumentValue(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
#endif
}
