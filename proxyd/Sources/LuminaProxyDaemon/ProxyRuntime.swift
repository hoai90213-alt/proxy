import Foundation
import Dispatch
import Network

struct ProxyTarget: Codable {
    var serverHost: String
    var serverPort: UInt16
}

struct ProxyControlBody: Codable {
    var serverHost: String?
    var serverPort: UInt16?
}

struct ProxyStatusSnapshot: Codable {
    var state: String
    var localProxyPort: UInt16
    var target: ProxyTarget?
    var updatedAt: String
    var message: String?
}

final class ProxyRuntime {
    private enum State: String {
        case stopped
        case starting
        case running
        case stopping
    }

    private let queue = DispatchQueue(label: "com.project.lumina.proxyd.runtime")
    private let config: DaemonConfig

    private var state: State = .stopped
    private var currentTarget: ProxyTarget?
    private var message: String?
    private var updatedAt: Date = .init()
    private var relay: UDPRelayEngine?

    init(config: DaemonConfig) {
        self.config = config

        if !config.remoteDefaultHost.isEmpty {
            self.currentTarget = ProxyTarget(
                serverHost: config.remoteDefaultHost,
                serverPort: config.remoteDefaultPort
            )
        }
    }

    func status() -> ProxyStatusSnapshot {
        queue.sync { snapshotLocked() }
    }

    func start(with body: ProxyControlBody?) -> ProxyStatusSnapshot {
        queue.sync {
            let targetHost = (body?.serverHost?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? currentTarget?.serverHost
                ?? (config.remoteDefaultHost.isEmpty ? nil : config.remoteDefaultHost)

            let targetPort = body?.serverPort ?? currentTarget?.serverPort ?? config.remoteDefaultPort

            guard let host = targetHost else {
                message = "Missing target host"
                touch()
                return snapshotLocked()
            }

            let nextTarget = ProxyTarget(serverHost: host, serverPort: targetPort)

            if state == .running {
                if currentTarget?.serverHost == nextTarget.serverHost && currentTarget?.serverPort == nextTarget.serverPort {
                    message = "Proxy already running"
                    touch()
                    return snapshotLocked()
                }

                relay?.stop()
                relay = nil
                state = .stopped
                message = "Proxy restarted with new target"
                touch()
            }

            state = .starting
            currentTarget = nextTarget
            message = "Proxy starting..."
            touch()

            do {
                let relay = try UDPRelayEngine(
                    localPort: config.localProxyPort,
                    target: nextTarget,
                    onEvent: { [weak self] event in
                        self?.queue.async {
                            guard let self else { return }
                            self.message = event
                            self.touch()
                        }
                    },
                    onFatal: { [weak self] errorMessage in
                        self?.queue.async {
                            guard let self else { return }
                            self.relay?.stop()
                            self.relay = nil
                            self.state = .stopped
                            self.message = errorMessage
                            self.touch()
                        }
                    }
                )
                try relay.start()
                self.relay = relay
            } catch {
                state = .stopped
                message = "Failed to start UDP relay: \(error)"
                touch()
                return snapshotLocked()
            }

            state = .running
            message = "Proxy running"
            touch()
            return snapshotLocked()
        }
    }

    func stop() -> ProxyStatusSnapshot {
        queue.sync {
            guard state != .stopped else {
                message = "Proxy already stopped"
                touch()
                return snapshotLocked()
            }

            state = .stopping
            message = "Proxy stopping..."
            touch()

            relay?.stop()
            relay = nil
            state = .stopped
            message = "Proxy stopped"
            touch()
            return snapshotLocked()
        }
    }

    func toggle(with body: ProxyControlBody?) -> ProxyStatusSnapshot {
        let current = status()
        return current.state == "running" ? stop() : start(with: body)
    }

    func applyRemoteCommand(_ cmd: RemoteCommandEnvelope) -> ProxyStatusSnapshot {
        switch cmd.command {
        case .start:
            return start(with: ProxyControlBody(serverHost: cmd.serverHost, serverPort: cmd.serverPort))
        case .stop:
            return stop()
        case .toggle:
            return toggle(with: ProxyControlBody(serverHost: cmd.serverHost, serverPort: cmd.serverPort))
        }
    }

    private func snapshotLocked() -> ProxyStatusSnapshot {
        ProxyStatusSnapshot(
            state: state.rawValue,
            localProxyPort: config.localProxyPort,
            target: currentTarget,
            updatedAt: ISO8601DateFormatter().string(from: updatedAt),
            message: message
        )
    }

    private func touch() {
        updatedAt = Date()
    }
}

private enum UDPRelayError: Error, CustomStringConvertible {
    case invalidPort(UInt16)
    case listenerInitFailed(String)

    var description: String {
        switch self {
        case .invalidPort(let port):
            return "invalid port \(port)"
        case .listenerInitFailed(let reason):
            return "listener init failed: \(reason)"
        }
    }
}

private final class UDPRelayEngine {
    private let localPort: UInt16
    private let target: ProxyTarget
    private let onEvent: (String) -> Void
    private let onFatal: (String) -> Void
    private let queue = DispatchQueue(label: "com.project.lumina.proxyd.udp")

    private var listener: NWListener?
    private var localConnection: NWConnection?
    private var remoteConnection: NWConnection?
    private var isStopping = false
    private var clientDescription: String?
    private var sessionGeneration: UInt64 = 0

    init(
        localPort: UInt16,
        target: ProxyTarget,
        onEvent: @escaping (String) -> Void,
        onFatal: @escaping (String) -> Void
    ) throws {
        self.localPort = localPort
        self.target = target
        self.onEvent = onEvent
        self.onFatal = onFatal

        guard NWEndpoint.Port(rawValue: localPort) != nil else {
            throw UDPRelayError.invalidPort(localPort)
        }
        guard NWEndpoint.Port(rawValue: target.serverPort) != nil else {
            throw UDPRelayError.invalidPort(target.serverPort)
        }
    }

    func start() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        guard let port = NWEndpoint.Port(rawValue: localPort) else {
            throw UDPRelayError.invalidPort(localPort)
        }

        do {
            let listener = try NWListener(using: params, on: port)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptLocalConnection(connection)
            }

            listener.start(queue: queue)
            onEvent("UDP listener starting on 127.0.0.1:\(localPort)")
        } catch {
            throw UDPRelayError.listenerInitFailed(String(describing: error))
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.sessionGeneration &+= 1
            self.localConnection?.cancel()
            self.remoteConnection?.cancel()
            self.listener?.cancel()
            self.localConnection = nil
            self.remoteConnection = nil
            self.listener = nil
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            onEvent("UDP listener ready on 127.0.0.1:\(localPort)")
        case .failed(let error):
            guard !isStopping else { return }
            onFatal("UDP listener failed: \(error)")
        case .cancelled:
            if !isStopping {
                onEvent("UDP listener cancelled")
            }
        default:
            break
        }
    }

    private func acceptLocalConnection(_ connection: NWConnection) {
        queue.async { [weak self] in
            guard let self else { return }

            let endpointDesc = Self.describe(endpoint: connection.endpoint)

            if self.localConnection != nil {
                self.onEvent("Replacing active client with \(endpointDesc)")
                self.localConnection?.cancel()
                self.remoteConnection?.cancel()
                self.localConnection = nil
                self.remoteConnection = nil
            }

            self.sessionGeneration &+= 1
            let generation = self.sessionGeneration
            self.clientDescription = endpointDesc
            self.localConnection = connection
            self.configureLocalConnection(connection, generation: generation)
            self.onEvent("Client connected: \(endpointDesc)")

            do {
                try self.ensureRemoteConnection(generation: generation)
            } catch {
                self.onFatal("Remote connection init failed: \(error)")
                return
            }

            self.receiveLoopFromLocal(generation: generation)
        }
    }

    private func configureLocalConnection(_ connection: NWConnection, generation: UInt64) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self else { return }
                guard generation == self.sessionGeneration else { return }
                switch state {
                case .ready:
                    self.onEvent("Local client UDP ready")
                case .failed(let error):
                    if !self.isStopping {
                        self.onEvent("Local client UDP failed: \(error)")
                    }
                    self.teardownSession(ifGeneration: generation)
                case .cancelled:
                    self.teardownSession(ifGeneration: generation)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func ensureRemoteConnection(generation: UInt64) throws {
        guard remoteConnection == nil else { return }
        guard let remotePort = NWEndpoint.Port(rawValue: target.serverPort) else {
            throw UDPRelayError.invalidPort(target.serverPort)
        }

        let conn = NWConnection(host: NWEndpoint.Host(target.serverHost), port: remotePort, using: .udp)
        remoteConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                guard let self else { return }
                guard generation == self.sessionGeneration else { return }
                switch state {
                case .ready:
                    self.onEvent("Remote UDP ready -> \(self.target.serverHost):\(self.target.serverPort)")
                    self.receiveLoopFromRemote(generation: generation)
                case .failed(let error):
                    if !self.isStopping {
                        self.onEvent("Remote UDP failed: \(error)")
                    }
                    self.teardownSession(ifGeneration: generation)
                case .cancelled:
                    self.teardownSession(ifGeneration: generation)
                default:
                    break
                }
            }
        }

        conn.start(queue: queue)
    }

    private func receiveLoopFromLocal(generation: UInt64) {
        guard let localConnection else { return }
        localConnection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.sessionGeneration else { return }
                if let error {
                    if !self.isStopping {
                        self.onEvent("Local receive error: \(error)")
                    }
                    self.teardownSession(ifGeneration: generation)
                    return
                }

                if let data, !data.isEmpty {
                    self.forwardToRemote(data, generation: generation)
                }

                if self.localConnection === localConnection && !self.isStopping {
                    self.receiveLoopFromLocal(generation: generation)
                }
            }
        }
    }

    private func receiveLoopFromRemote(generation: UInt64) {
        guard let remoteConnection else { return }
        remoteConnection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.queue.async {
                guard generation == self.sessionGeneration else { return }
                if let error {
                    if !self.isStopping {
                        self.onEvent("Remote receive error: \(error)")
                    }
                    self.teardownSession(ifGeneration: generation)
                    return
                }

                if let data, !data.isEmpty {
                    self.forwardToLocal(data, generation: generation)
                }

                if self.remoteConnection === remoteConnection && !self.isStopping {
                    self.receiveLoopFromRemote(generation: generation)
                }
            }
        }
    }

    private func forwardToRemote(_ data: Data, generation: UInt64) {
        guard let remoteConnection else { return }
        remoteConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error, !self.isStopping {
                self.queue.async {
                    guard generation == self.sessionGeneration else { return }
                    self.onEvent("Forward to remote failed: \(error)")
                    self.teardownSession(ifGeneration: generation)
                }
            }
        })
    }

    private func forwardToLocal(_ data: Data, generation: UInt64) {
        guard let localConnection else { return }
        localConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error, !self.isStopping {
                self.queue.async {
                    guard generation == self.sessionGeneration else { return }
                    self.onEvent("Forward to local failed: \(error)")
                    self.teardownSession(ifGeneration: generation)
                }
            }
        })
    }

    private func teardownSession(ifGeneration generation: UInt64) {
        guard generation == sessionGeneration else { return }
        localConnection?.cancel()
        remoteConnection?.cancel()
        localConnection = nil
        remoteConnection = nil
        if let clientDescription {
            onEvent("Client disconnected: \(clientDescription)")
        }
        clientDescription = nil
    }

    private static func describe(endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "\(endpoint)"
        }
    }
}
