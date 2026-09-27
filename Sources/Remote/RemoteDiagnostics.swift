import Foundation
import OSLog

final class RemoteDiagnostics: @unchecked Sendable {
    static let shared = RemoteDiagnostics()

    enum Level: String {
        case debug
        case info
        case warning
        case error
    }

    let fileURL: URL
    let previousFileURL: URL

    private let sessionID = UUID().uuidString
    private let queue = DispatchQueue(label: "io.github.LJY0317.PluraMobile.remote-diagnostics")
    private let console = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.LJY0317.PluraMobile",
        category: "RemoteDiagnostics"
    )
    private let maxFileBytes = 2 * 1_024 * 1_024
    private let verboseDebugEnabled: Bool

    private init() {
        verboseDebugEnabled = ProcessInfo.processInfo.arguments.contains("--remote-diagnostics-verbose")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = documents.appendingPathComponent("remote-diagnostics.jsonl")
        previousFileURL = documents.appendingPathComponent("remote-diagnostics.previous.jsonl")
        ensureCurrentFileExists()

        let info = Bundle.main.infoDictionary
        record("diagnostics.session.started", fields: [
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "verboseDebugEnabled": verboseDebugEnabled
        ])
    }

    func record(_ event: String, level: Level = .info, fields: [String: Any] = [:]) {
        if level == .debug && !verboseDebugEnabled { return }

        var object = fields
        object["timestamp"] = ISO8601DateFormatter().string(from: Date())
        object["sessionID"] = sessionID
        object["event"] = event
        object["level"] = level.rawValue

        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: json, encoding: .utf8)
        else {
            console.error("Failed to serialize diagnostics event: \(event, privacy: .public)")
            return
        }

        switch level {
        case .debug: console.debug("\(line, privacy: .public)")
        case .info: console.info("\(line, privacy: .public)")
        case .warning: console.warning("\(line, privacy: .public)")
        case .error: console.error("\(line, privacy: .public)")
        }

        var payload = json
        payload.append(0x0A)
        let payloadToWrite = payload
        let fileURL = fileURL
        let previousFileURL = previousFileURL
        let maxFileBytes = maxFileBytes
        queue.async {
            let manager = FileManager.default
            let currentSize = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if currentSize + payloadToWrite.count > maxFileBytes {
                try? manager.removeItem(at: previousFileURL)
                if manager.fileExists(atPath: fileURL.path) {
                    try? manager.moveItem(at: fileURL, to: previousFileURL)
                }
                manager.createFile(atPath: fileURL.path, contents: nil)
            }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payloadToWrite)
                } catch {
                    // Unified logging above remains available if file logging fails.
                }
            }
        }
    }

    func clear() {
        let fileURL = fileURL
        let previousFileURL = previousFileURL
        queue.async {
            let manager = FileManager.default
            try? manager.removeItem(at: previousFileURL)
            try? manager.removeItem(at: fileURL)
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        record("diagnostics.cleared")
    }

    private func ensureCurrentFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }
}

final class RemoteWebSocketDiagnosticsDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let diagnostics: RemoteDiagnostics

    init(diagnostics: RemoteDiagnostics) {
        self.diagnostics = diagnostics
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        var fields = taskFields(webSocketTask)
        fields["negotiatedProtocol"] = `protocol` ?? ""
        diagnostics.record("websocket.didOpen", fields: fields)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        var fields = taskFields(webSocketTask)
        fields["closeCode"] = closeCode.rawValue
        fields["reasonBytes"] = reason?.count ?? 0
        if let reason, let text = String(data: reason, encoding: .utf8) {
            fields["reason"] = String(text.prefix(512))
        }
        diagnostics.record("websocket.didClose", fields: fields)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var fields = taskFields(task)
        fields["hasError"] = error != nil
        if let error {
            let value = error as NSError
            fields["errorDomain"] = value.domain
            fields["errorCode"] = value.code
            fields["errorDescription"] = value.localizedDescription
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
                fields["underlyingErrorDomain"] = underlying.domain
                fields["underlyingErrorCode"] = underlying.code
            }
        }
        diagnostics.record(
            "urlSession.task.completed",
            level: error == nil ? .debug : .error,
            fields: fields
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        var fields = taskFields(task)
        fields["redirectCount"] = metrics.redirectCount
        fields["transactionCount"] = metrics.transactionMetrics.count
        fields["taskDurationMs"] = metrics.taskInterval.duration * 1_000
        if let transaction = metrics.transactionMetrics.last {
            fields["networkProtocol"] = transaction.networkProtocolName ?? ""
            fields["isProxyConnection"] = transaction.isProxyConnection
            fields["isReusedConnection"] = transaction.isReusedConnection
            fields["resourceFetchType"] = transaction.resourceFetchType.rawValue
        }
        diagnostics.record("urlSession.task.metrics", level: .debug, fields: fields)
    }

    private func taskFields(_ task: URLSessionTask) -> [String: Any] {
        var fields: [String: Any] = [
            "taskID": task.taskIdentifier,
            "state": taskStateName(task.state),
            "requestScheme": task.originalRequest?.url?.scheme ?? "",
            "requestHost": task.originalRequest?.url?.host ?? "",
            "requestPort": task.originalRequest?.url?.port ?? -1
        ]
        if let response = task.response as? HTTPURLResponse {
            fields["httpStatus"] = response.statusCode
            fields["mimeType"] = response.mimeType ?? ""
            fields["expectedContentLength"] = response.expectedContentLength
        }
        return fields
    }

    private func taskStateName(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: "running"
        case .suspended: "suspended"
        case .canceling: "canceling"
        case .completed: "completed"
        @unknown default: "unknown"
        }
    }
}
