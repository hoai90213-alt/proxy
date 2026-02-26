import Foundation
import Dispatch

func makeConfigURL() -> URL {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }

    // Typical jailbreak daemon location; override via argv if you prefer another path.
    return URL(fileURLWithPath: "/var/mobile/Library/Preferences/com.project.lumina.proxyd.json")
}

do {
    let configURL = makeConfigURL()
    let config = try DaemonConfig.loadOrCreate(at: configURL)
    let runtime = ProxyRuntime(config: config)
    let server = try ControlHTTPServer(config: config, runtime: runtime)
    let poller = WebCommandPoller(config: config, runtime: runtime)

    server.start()
    poller.startIfConfigured()

    print("[LuminaProxyDaemon] Ready on http://\(config.controlBindHost):\(config.controlPort)")
    dispatchMain()
} catch {
    fputs("[LuminaProxyDaemon] Fatal error: \(error)\n", stderr)
    exit(1)
}

