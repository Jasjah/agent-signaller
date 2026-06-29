import AppKit
import SignalerCore

// AgentSignaller.app — an always-visible corner badge showing aggregate AI agent
// status. Runs as an accessory app (no Dock icon, no menu bar item).

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: BadgeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = BadgeController()
        controller.start()
        self.controller = controller
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // backstop for LSUIElement
let delegate = AppDelegate()
app.delegate = delegate
app.run()
