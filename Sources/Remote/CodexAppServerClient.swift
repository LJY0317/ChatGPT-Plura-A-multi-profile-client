import Foundation

enum CodexRequestID: Hashable {
    case integer(Int)
    case string(String)

    init?(value: Any?) {
        if let value = value as? Int { self = .integer(value); return }
        if let value = value as? NSNumber { self = .integer(value.intValue); return }
        if let value = value as? String { self = .string(value); return }
        return nil
    }

    var jsonValue: Any {
        switch self {
        case .integer(let value): value
        case .string(let value): value
        }
    }
}

@MainActor
final class CodexAppServerClient {
    typealias ResponseHandler = @MainActor (Int, [String: Any]) -> Void
    typealias NotificationHandler = @MainActor (String, [String: Any]) -> Void
    typealias ServerRequestHandler = @MainActor (CodexRequestID, String, [String: Any]) -> Void
    typealias FailureHandler = @MainActor (Error) -> Void

    private let diagnostics: RemoteDiagnostics
    private let transport: RemoteWebSocketTransport
    private var responseHandler: ResponseHandler?
    private var notificationHandler: NotificationHandler?
    private var serverRequestHandler: ServerRequestHandler?
    private var failureHandler: FailureHandler?

    init(diagnostics: RemoteDiagnostics = .shared) {
        self.diagnostics = diagnostics
        transport = RemoteWebSocketTransport(diagnostics: diagnostics)
    }

    var isActive: Bool { transport.isActive }
    var taskID: Int { transport.taskID }

    func connect(
        url: URL,
        token: String,
        onResponse: @escaping ResponseHandler,
        onNotification: @escaping NotificationHandler,
        onServerRequest: @escaping ServerRequestHandler,
        onFailure: @escaping FailureHandler
    ) {
        responseHandler = onResponse
        notificationHandler = onNotification
        serverRequestHandler = onServerRequest
        failureHandler = onFailure
        transport.connect(
            url: url,
            token: token,
            onMessage: { [weak self] data in self?.handle(data) },
            onFailure: { [weak self] error in self?.failureHandler?(error) }
        )
    }

    func sendRequest(id: Int, method: String, params: [String: Any]) {
        sendJSONObject(["method": method, "id": id, "params": params])
    }

    func sendNotification(method: String) {
        diagnostics.record("notification.sent", fields: ["method": method])
        sendJSONObject(["method": method])
    }

    func sendServerResponse(id: CodexRequestID, result: [String: Any]) {
        diagnostics.record("serverRequest.response.sent", fields: ["resultKeys": result.keys.sorted()])
        sendJSONObject(["id": id.jsonValue, "result": result])
    }

    func sendServerError(id: CodexRequestID, code: Int, message: String) {
        diagnostics.record("serverRequest.error.sent", level: .warning, fields: [
            "code": code,
            "message": message
        ])
        sendJSONObject([
            "id": id.jsonValue,
            "error": ["code": code, "message": message]
        ])
    }

    func disconnect(reason: String) {
        transport.disconnect(reason: reason)
        responseHandler = nil
        notificationHandler = nil
        serverRequestHandler = nil
        failureHandler = nil
    }

    private func sendJSONObject(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let method = object["method"] as? String ?? ""
            let requestID = requestID(from: object["id"]) ?? -1
            transport.send(data: data, method: method, requestID: requestID) { [weak self] error in
                self?.failureHandler?(error)
            }
        } catch {
            diagnostics.record("protocol.encode.failed", level: .error, fields: errorFields(error))
            failureHandler?(error)
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            diagnostics.record("protocol.decode.failed", level: .error, fields: ["bytes": data.count])
            return
        }
        if let method = object["method"] as? String,
           let id = CodexRequestID(value: object["id"]),
           let params = object["params"] as? [String: Any]
        {
            diagnostics.record("protocol.serverRequest.received", fields: [
                "method": method,
                "paramKeys": params.keys.sorted()
            ])
            serverRequestHandler?(id, method, params)
            return
        }
        if let id = requestID(from: object["id"]) {
            diagnostics.record("protocol.response.received", level: .debug, fields: [
                "id": id,
                "keys": object.keys.sorted(),
                "hasError": object["error"] != nil
            ])
            responseHandler?(id, object)
            return
        }
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else {
            diagnostics.record("protocol.notification.invalid", level: .warning, fields: ["keys": object.keys.sorted()])
            return
        }
        diagnostics.record("protocol.notification.received", level: .debug, fields: [
            "method": method,
            "paramKeys": params.keys.sorted()
        ])
        notificationHandler?(method, params)
    }

    private func requestID(from value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
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
