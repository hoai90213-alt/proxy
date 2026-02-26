import Foundation
import Network
import Dispatch

final class ControlHTTPServer {
    private let config: DaemonConfig
    private let runtime: ProxyRuntime
    private let queue = DispatchQueue(label: "com.project.lumina.proxyd.http")
    private let listener: NWListener

    init(config: DaemonConfig, runtime: ProxyRuntime) throws {
        self.config = config
        self.runtime = runtime

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: config.controlPort)!
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(config.controlBindHost), port: port)
        self.listener = try NWListener(using: params, on: port)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            print("[ControlHTTPServer] state=\(state)")
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                print("[ControlHTTPServer] receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let response = self.process(data: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                if isComplete {
                    connection.cancel()
                } else {
                    connection.cancel()
                }
            })
        }
    }

    private func process(data: Data) -> Data {
        guard let request = HTTPRequest.parse(data) else {
            return httpJSON(status: 400, object: ["error": "invalid_http_request"])
        }

        if !isAuthorized(request) {
            return httpJSON(status: 401, object: ["error": "unauthorized"])
        }

        switch (request.method, request.path) {
        case ("GET", "/healthz"):
            return httpJSON(status: 200, object: ["ok": true])
        case ("GET", "/status"):
            return encodeStatus(runtime.status())
        case ("POST", "/proxy/start"):
            return encodeStatus(runtime.start(with: parseControlBody(from: request.body)))
        case ("POST", "/proxy/stop"):
            return encodeStatus(runtime.stop())
        case ("POST", "/proxy/toggle"):
            return encodeStatus(runtime.toggle(with: parseControlBody(from: request.body)))
        default:
            return httpJSON(status: 404, object: ["error": "not_found"])
        }
    }

    private func parseControlBody(from data: Data) -> ProxyControlBody? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ProxyControlBody.self, from: data)
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        let expected = config.controlAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if expected.isEmpty {
            return true
        }

        guard let auth = request.headers["authorization"] else { return false }
        return auth == "Bearer \(expected)"
    }

    private func encodeStatus(_ status: ProxyStatusSnapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(status)) ?? Data("{\"error\":\"encode_failed\"}".utf8)
        return http(status: 200, contentType: "application/json", body: body)
    }

    private func httpJSON(status: Int, object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return http(status: status, contentType: "application/json", body: body)
    }

    private func http(status: Int, contentType: String, body: Data) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        var raw = "HTTP/1.1 \(status) \(statusText)\r\n"
        raw += "Content-Type: \(contentType)\r\n"
        raw += "Content-Length: \(body.count)\r\n"
        raw += "Connection: close\r\n\r\n"

        var data = Data(raw.utf8)
        data.append(body)
        return data
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }

        let headerData = data.subdata(in: 0..<range.lowerBound)
        let body = data.subdata(in: range.upperBound..<data.count)

        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0]).uppercased()
        let path = String(requestParts[1]).components(separatedBy: "?").first ?? String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
