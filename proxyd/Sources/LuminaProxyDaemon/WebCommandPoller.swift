import Foundation
import Dispatch

enum RemoteCommandType: String, Codable {
    case start
    case stop
    case toggle
}

struct RemoteCommandEnvelope: Codable {
    var command: RemoteCommandType
    var commandId: String?
    var deviceId: String?
    var serverHost: String?
    var serverPort: UInt16?
    var nonce: String?
    var timestamp: Date?
    var signature: String?
}

final class WebCommandPoller {
    private let config: DaemonConfig
    private let runtime: ProxyRuntime
    private let queue = DispatchQueue(label: "com.project.lumina.proxyd.poller")
    private var timer: DispatchSourceTimer?

    init(config: DaemonConfig, runtime: ProxyRuntime) {
        self.config = config
        self.runtime = runtime
    }

    func startIfConfigured() {
        guard let rawURL = config.remoteCommandURL, !rawURL.isEmpty else {
            print("[WebCommandPoller] disabled (remoteCommandURL not set)")
            return
        }

        guard URL(string: rawURL) != nil else {
            print("[WebCommandPoller] invalid remoteCommandURL")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: config.commandPollIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        self.timer = timer
        timer.resume()

        print("[WebCommandPoller] enabled -> \(rawURL)")
    }

    private func pollOnce() {
        guard let rawURL = config.remoteCommandURL, let url = URL(string: rawURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-Id")
        if let bearer = config.remoteCommandBearerToken, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, _, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 6)

        if let responseError {
            print("[WebCommandPoller] request error: \(responseError)")
            return
        }

        guard let data = responseData, !data.isEmpty else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let command = try? decoder.decode(RemoteCommandEnvelope.self, from: data) else {
            print("[WebCommandPoller] invalid command payload")
            return
        }

        guard isCommandFresh(command) else {
            print("[WebCommandPoller] stale command dropped")
            return
        }

        // TODO: Verify signature / nonce replay before applying command.
        let status = runtime.applyRemoteCommand(command)
        print("[WebCommandPoller] applied \(command.command.rawValue) -> \(status.state)")
    }

    private func isCommandFresh(_ command: RemoteCommandEnvelope) -> Bool {
        guard let ts = command.timestamp else { return true }
        return abs(Date().timeIntervalSince(ts)) <= config.commandMaxSkewSeconds
    }
}
