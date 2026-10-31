import AppKit

/// Process-wide lifecycle that doesn't belong to any one model.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Being killed with SIGTERM (kill, pkill, a shutdown) skips willTerminate, which left the flutter tool
        // running with nobody to talk to it. Turn those signals into a normal quit so models can clean up.
        for signalNumber in [SIGTERM, SIGHUP, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
