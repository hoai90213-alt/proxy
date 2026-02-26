import Foundation

struct DaemonConfig: Codable {
    var deviceId: String
    var controlBindHost: String
    var controlPort: UInt16
    var controlAuthToken: String

    var localProxyPort: UInt16
    var remoteDefaultHost: String
    var remoteDefaultPort: UInt16

    var remoteCommandURL: String?
    var remoteCommandBearerToken: String?
    var commandPollIntervalSeconds: Double
    var commandMaxSkewSeconds: Double

    static func `default`() -> DaemonConfig {
        DaemonConfig(
            deviceId: UUID().uuidString.lowercased(),
            controlBindHost: "127.0.0.1",
            controlPort: 8787,
            controlAuthToken: "change-me",
            localProxyPort: 19132,
            remoteDefaultHost: "",
            remoteDefaultPort: 19132,
            remoteCommandURL: nil,
            remoteCommandBearerToken: nil,
            commandPollIntervalSeconds: 2.0,
            commandMaxSkewSeconds: 30.0
        )
    }

    static func loadOrCreate(at url: URL) throws -> DaemonConfig {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(DaemonConfig.self, from: data)
        }

        let config = DaemonConfig.default()
        try persist(config, to: url)
        return config
    }

    static func persist(_ config: DaemonConfig, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
