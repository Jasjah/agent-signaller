import AppKit
import SignalerCore

/// Brings the terminal tab that a session runs in to the front.
///
/// For Terminal.app and iTerm2 we use AppleScript to select the tab/session
/// whose `tty` matches the one captured at hook time. (The first AppleScript
/// call triggers a one-time macOS Automation permission prompt.) When the tty
/// is unknown or the app isn't scriptable, we fall back to just activating the
/// terminal application.
enum TerminalFocus {
    static func focus(_ session: Session) {
        let program = session.termProgram ?? ""
        let tty = session.tty

        switch program {
        case "Apple_Terminal":
            if let tty = tty, !tty.isEmpty {
                run(terminalAppScript(tty: tty))
            } else {
                activate("Terminal")
            }
        case "iTerm.app", "iTerm2":
            if let tty = tty, !tty.isEmpty {
                run(iTermScript(tty: tty))
            } else {
                activate("iTerm")
            }
        default:
            // Unknown / non-scriptable terminal: best effort.
            if let bundleName = program.isEmpty ? nil : program {
                activate(bundleName.replacingOccurrences(of: ".app", with: ""))
            }
        }
    }

    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) is "\(escape(tty))" then
                            set selected of t to true
                            set frontmost of w to true
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (tty of s) is "\(escape(tty))" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func activate(_ appName: String) {
        run("tell application \"\(escape(appName))\" to activate")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) {
        // AppleScript must run on the main thread.
        let work = {
            var error: NSDictionary?
            if let script = NSAppleScript(source: source) {
                script.executeAndReturnError(&error)
                if let error = error {
                    NSLog("agent-signaller: AppleScript focus failed: \(error)")
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
