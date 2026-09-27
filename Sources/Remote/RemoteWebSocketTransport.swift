import Foundation

@MainActor
final class RemoteWebSocketTransport {
    static let maximumMessageSize = 16 * 1024 * 1024

    private let diagnostics: RemoteDiagnostics
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionDelegate: RemoteWebSocketDiagnosticsDelegate?
    private var receiveTask: Task<Void, Never>?

    var isActive: Bool { socket != nil }
    var taskID: Int { socket?.taskIdentifier ?? -1 }

    init(diagnostics: RemoteDiagnostics = .shared) {
        self.diagnostics = diagnostics
    }

    func connect(
        url: URL,
        token: String,
        onMessage: @escaping @MainActor (Data) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        disconnect(reason: "transport.replace")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let delegate = RemoteWebSocketDiagnosticsDelegate(diagnostics: diagnostics)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let defaultMaximum = task.maximumMessageSize
        task.maximumMessageSize = Self.maximumMessageSize
        urlSession = session
        sessionDelegate = delegate
        socket = task
        diagnostics.record("websocket.task.created", fields: [
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "port": url.port ?? -1,
            "taskID": task.taskIdentifier,
            "defaultMaximumMessageSize": defaultMaximum,
            "maximumMessageSize": task.maximumMessageSize
        ])
        task.resume()
        diagnostics.record("websocket.task.resumed", fields: ["taskID": task.taskIdentifier])
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task, onMessage: onMessage, onFailure: onFailure)
        }
    }

    func send(data: Data, method: String, requestID: Int, onFailure: @escaping @MainActor (Error) -> Void) {
        guard let socket else {
            diagnostics.record("websocket.send.skipped", level: .error, fields: [
                "method": method,
                "reason": "missingSocket"
            ])
            return
        }
        guard let string = String(data: data, encoding: .utf8) else { return }
        let taskID = socket.taskIdentifier
        diagnostics.record("websocket.send", level: .debug, fields: [
            "method": method,
            "id": requestID,
            "bytes": data.count,
            "taskID": taskID
        ])
        socket.send(.string(string)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.diagnostics.record("websocket.send.failed", level: .error, fields: self.errorFields(error, taskID: taskID))
                    onFailure(error)
                } else {
                    self.diagnostics.record("websocket.send.completed", level: .debug, fields: [
                        "taskID": taskID,
                        "method": method,
                        "id": requestID
                    ])
                }
            }
        }
    }

    func disconnect(reason: String) {
        diagnostics.record("websocket.transport.disconnect", level: .debug, fields: [
            "reason": reason,
            "hadSocket": socket != nil,
            "taskID": taskID
        ])
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        sessionDelegate = nil
    }

    private func receiveLoop(
        _ task: URLSessionWebSocketTask,
        onMessage: @escaping @MainActor (Data) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async {
        diagnostics.record("websocket.receiveLoop.started", fields: ["taskID": task.taskIdentifier])
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                let type: String
                switch message {
                case .string(let string): data = Data(string.utf8); type = "string"
                case .data(let value): data = value; type = "data"
                @unknown default:
                    diagnostics.record("websocket.receive.unknownType", level: .warning)
                    continue
                }
                diagnostics.record("websocket.receive", level: .debug, fields: [
                    "type": type,
                    "bytes": data.count,
                    "taskID": task.taskIdentifier
                ])
                onMessage(data)
            } catch {
                if !Task.isCancelled {
                    diagnostics.record("websocket.receive.failed", level: .error, fields: errorFields(error, taskID: task.taskIdentifier))
                    onFailure(error)
                }
                return
            }
        }
    }

    private func errorFields(_ error: Error, taskID: Int) -> [String: Any] {
        let value = error as NSError
        return [
            "taskID": taskID,
            "domain": value.domain,
            "code": value.code,
            "description": value.localizedDescription
        ]
    }
}
