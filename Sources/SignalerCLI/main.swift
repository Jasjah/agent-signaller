import Foundation
import SignalerCore

// agent-signaller — CLI bridge between AI agents and the floating badge app.
//
// Usage:
//   agent-signaller report --source claude --state working   (reads hook JSON on stdin)
//   agent-signaller report --source claude --remove           (clears the session)
//   agent-signaller report --source codex '<json>'            (Codex passes JSON as argv)
//   agent-signaller install [--bin /path/to/agent-signaller]  (wire Claude + Codex config)
//   agent-signaller gc
//   agent-signaller status

let store = SessionStore()
func now() -> Double { Date().timeIntervalSince1970 }

func fail(_ msg: String) -> Never {
    FileError.printToStderr("agent-signaller: \(msg)")
    exit(1)
}

enum FileError {
    static func printToStderr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

// Tiny flag parser over the argument list (after the subcommand).
struct Flags {
    var values: [String: String] = [:]
    var booleans: Set<String> = []
    var positionals: [String] = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]
                    i += 2
                } else {
                    booleans.insert(key)
                    i += 1
                }
            } else {
                positionals.append(a)
                i += 1
            }
        }
    }

    func has(_ k: String) -> Bool { booleans.contains(k) || values[k] != nil }
}

func readStdinJSON() -> [String: Any] {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Collapse a prompt into a short single-line topic for the hover tooltip.
func shortTitle(_ s: String, max: Int = 100) -> String {
    let collapsed = s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
    if collapsed.count <= max { return collapsed }
    return String(collapsed.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
}

func parseJSON(_ s: String) -> [String: Any] {
    guard let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return obj
}

/// Best-effort capture of the terminal tab this agent runs in, so a click on the
/// badge can later focus it. Env vars are inherited by the hook process; the tty
/// is resolved from our controlling terminal, falling back to the parent
/// (the agent process) since hooks may be spawned detached from the tty.
struct TerminalInfo {
    var program: String?
    var sessionId: String?
    var tty: String?
}

func captureTerminal() -> TerminalInfo {
    let env = ProcessInfo.processInfo.environment
    let program = env["TERM_PROGRAM"]
    let sessionId = env["TERM_SESSION_ID"] ?? env["ITERM_SESSION_ID"]
    var tty: String? = nil

    // 1) our own controlling terminal
    let fd = open("/dev/tty", O_RDONLY)
    if fd >= 0 {
        var buf = [CChar](repeating: 0, count: 256)
        if ttyname_r(fd, &buf, buf.count) == 0 {
            tty = String(cString: buf)
        }
        close(fd)
    }
    // 2) fall back to the parent process's tty
    if tty == nil || tty?.isEmpty == true {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(getppid())]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty && out != "??" && out != "?" {
                tty = out.hasPrefix("/dev/") ? out : "/dev/\(out)"
            }
        }
    }
    if tty?.isEmpty == true { tty = nil }
    return TerminalInfo(program: program, sessionId: sessionId, tty: tty)
}

// MARK: - report

func cmdReport(_ flags: Flags) {
    let source = flags.values["source"] ?? "claude"
    switch source {
    case "claude":
        reportFromStdin(tool: .claude, idPrefix: "", flags: flags)
    case "codex":
        // Modern Codex (>= v0.117) fires real hooks with the same stdin JSON
        // shape as Claude (session_id, cwd, prompt, transcript_path).
        reportFromStdin(tool: .codex, idPrefix: "codex-", flags: flags)
    case "codex-notify":
        reportCodexNotify(flags)
    default:
        fail("unknown --source \(source) (expected claude, codex, or codex-notify)")
    }
}

/// Handle a hook that delivers its event JSON on stdin (Claude Code and modern
/// Codex hooks share this shape).
func reportFromStdin(tool: AgentTool, idPrefix: String, flags: Flags) {
    let json = readStdinJSON()
    let sid = (json["session_id"] as? String) ?? "unknown"
    let id = idPrefix + sid
    let cwd = (json["cwd"] as? String) ?? ""
    if flags.has("remove") {
        store.remove(id: id)
        return
    }
    guard let stateRaw = flags.values["state"], let state = AgentState(rawValue: stateRaw) else {
        fail("report --source \(tool.rawValue) requires --state working|waiting|done (or --remove)")
    }
    let term = captureTerminal()
    let transcript = json["transcript_path"] as? String
    let title = (json["prompt"] as? String).map { shortTitle($0) }
    do {
        try store.upsert(id: id, tool: tool, state: state, cwd: cwd, now: now(),
                         termProgram: term.program, termSessionId: term.sessionId, tty: term.tty,
                         transcriptPath: transcript, title: title)
    } catch {
        fail("could not write session: \(error)")
    }
}

/// Legacy Codex `notify` program: event JSON arrives as a single argv string and
/// only ever signals turn completion (done).
func reportCodexNotify(_ flags: Flags) {
    let json = flags.positionals.last.map(parseJSON) ?? [:]
    let thread = (json["thread-id"] as? String) ?? (json["thread_id"] as? String) ?? "unknown"
    let id = "codex-\(thread)"
    let cwd = (json["cwd"] as? String) ?? ""
    if flags.has("remove") { store.remove(id: id); return }
    let inputs = (json["input-messages"] as? [String]) ?? (json["input_messages"] as? [String])
    let title = inputs?.joined(separator: " ").nonEmpty.map { shortTitle($0) }
    let term = captureTerminal()
    do {
        try store.upsert(id: id, tool: .codex, state: .done, cwd: cwd, now: now(),
                         termProgram: term.program, termSessionId: term.sessionId, tty: term.tty,
                         title: title)
    } catch {
        fail("could not write session: \(error)")
    }
}

// MARK: - install

/// Path to use in the generated hook commands. Defaults to this binary's own
/// location so `agent-signaller install` works wherever it was installed
/// (Homebrew prefix, app bundle, etc.); overridable with --bin.
func defaultBinPath() -> String {
    if let p = Bundle.main.executablePath { return p }
    return CommandLine.arguments.first ?? "/usr/local/bin/agent-signaller"
}

func cmdInstall(_ flags: Flags) {
    let bin = flags.values["bin"] ?? defaultBinPath()
    installClaudeHooks(bin: bin)
    installCodexHooks(bin: bin)
    print("agent-signaller: install complete (bin: \(bin))")
    print("  • Claude hooks  → ~/.claude/settings.json")
    print("  • Codex hooks   → ~/.codex/hooks.json  (requires Codex >= v0.117)")
}

func backup(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let bak = url.appendingPathExtension("agent-signaller.bak")
    try? FileManager.default.removeItem(at: bak)
    try? FileManager.default.copyItem(at: url, to: bak)
}

func installClaudeHooks(bin: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent(".claude", isDirectory: true)
    let url = dir.appendingPathComponent("settings.json")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        root = obj
    }

    func entry(_ state: String?, remove: Bool = false) -> [String: Any] {
        var cmd = "\(bin) report --source claude"
        if remove { cmd += " --remove" } else if let s = state { cmd += " --state \(s)" }
        return ["matcher": "*", "hooks": [["type": "command", "command": cmd]]]
    }

    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    hooks["UserPromptSubmit"] = [entry("working")]
    // Yellow only on a genuine permission/approval dialog. We deliberately do
    // NOT hook the generic Notification event: it also fires for the idle
    // "Claude is waiting for your input" nudge, which would turn a finished
    // (green) session yellow ~60s later even though no decision is open.
    hooks["PermissionRequest"] = [entry("waiting")]
    hooks["Stop"]             = [entry("done")]
    hooks["SessionEnd"]       = [entry(nil, remove: true)]

    // Remove any Notification hook we wired in a previous version.
    if var notif = hooks["Notification"] as? [[String: Any]] {
        notif.removeAll { blk in
            (blk["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("agent-signaller") == true } == true
        }
        if notif.isEmpty { hooks["Notification"] = nil } else { hooks["Notification"] = notif }
    }
    root["hooks"] = hooks

    backup(url)
    let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    if let data = data {
        try? data.write(to: url, options: .atomic)
    } else {
        fail("could not serialize ~/.claude/settings.json")
    }
}

func installCodexHooks(bin: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent(".codex", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // Modern Codex hooks give the full working/waiting/done cycle. Written to
    // ~/.codex/hooks.json (auto-discovered by Codex).
    let url = dir.appendingPathComponent("hooks.json")
    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        root = obj
    }
    func entry(_ state: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": "\(bin) report --source codex --state \(state)"]]]
    }
    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    hooks["UserPromptSubmit"]  = [entry("working")]
    hooks["PermissionRequest"] = [entry("waiting")]
    hooks["Stop"]              = [entry("done")]
    root["hooks"] = hooks
    backup(url)
    if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    } else {
        fail("could not serialize ~/.codex/hooks.json")
    }

    // Remove the legacy top-level `notify` line we used to add to config.toml.
    let cfg = dir.appendingPathComponent("config.toml")
    if let existing = try? String(contentsOf: cfg, encoding: .utf8),
       existing.contains("agent-signaller") {
        let kept = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !($0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") && $0.contains("agent-signaller")) }
            .joined(separator: "\n")
        backup(cfg)
        try? kept.write(to: cfg, atomically: true, encoding: .utf8)
    }
}

// MARK: - main

let argv = Array(CommandLine.arguments.dropFirst())
guard let sub = argv.first else {
    print("usage: agent-signaller <report|install|gc|status> [flags]")
    exit(0)
}
let flags = Flags(Array(argv.dropFirst()))

switch sub {
case "report":
    cmdReport(flags)
case "install":
    cmdInstall(flags)
case "gc":
    let n = store.gc(now: now())
    let c = store.pruneClosedTerminals()
    print("pruned \(n) stale + \(c) closed-terminal session(s)")
case "status":
    let agg = store.aggregate(now: now())
    print(agg?.rawValue ?? "idle")
    for (id, s) in store.all().sorted(by: { $0.id < $1.id }) {
        let term = [s.termProgram, s.tty].compactMap { $0 }.joined(separator: " ")
        print("  \(id)  \(s.tool.rawValue)  \(s.state.rawValue)  \(s.cwd)  [\(term)]")
    }
case "active":
    // What the badge shows: live (non-stale) sessions.
    let live = store.liveSorted(now: now())
    for (id, s) in live {
        print("  \(id)  \(s.tool.rawValue)  \(s.state.rawValue)")
    }
    if live.isEmpty { print("  (idle)") }
default:
    fail("unknown command \(sub)")
}
