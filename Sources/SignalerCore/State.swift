import Foundation

/// The traffic-light state reported by a single agent session.
public enum AgentState: String, Codable, CaseIterable {
    case working   // 🔴 actively doing work
    case waiting   // 🟡 blocked, needs the user (permission / input)
    case done      // 🟢 finished its turn / idle

    /// Higher rank wins when aggregating across sessions.
    /// working > waiting > done, so "anything still churning" shows red.
    var rank: Int {
        switch self {
        case .working: return 3
        case .waiting: return 2
        case .done:    return 1
        }
    }
}

/// Which tool produced a session.
public enum AgentTool: String, Codable {
    case claude
    case codex
}

/// One agent session's last reported status. Persisted as a single JSON file.
public struct Session: Codable {
    public var tool: AgentTool
    public var state: AgentState
    public var cwd: String
    public var updated: Double  // epoch seconds
    // Terminal identity, captured at report time so a click can focus the tab.
    public var termProgram: String?   // e.g. "Apple_Terminal", "iTerm.app"
    public var termSessionId: String? // TERM_SESSION_ID / ITERM_SESSION_ID
    public var tty: String?           // e.g. "/dev/ttys003"
    public var transcriptPath: String?
    /// Short human-readable topic (the latest user prompt) shown on hover.
    public var title: String?

    public init(tool: AgentTool, state: AgentState, cwd: String, updated: Double,
                termProgram: String? = nil, termSessionId: String? = nil, tty: String? = nil,
                transcriptPath: String? = nil, title: String? = nil) {
        self.tool = tool
        self.state = state
        self.cwd = cwd
        self.updated = updated
        self.termProgram = termProgram
        self.termSessionId = termSessionId
        self.tty = tty
        self.transcriptPath = transcriptPath
        self.title = title
    }
}

/// File-backed store of sessions under ~/.agent-signaller/sessions/.
///
/// This is the single source of truth shared by the CLI (writer) and the
/// app (reader). Writes are atomic so a reader never sees a half-written file.
public struct SessionStore {
    public let root: URL
    public let sessionsDir: URL

    /// Default TTL after which a session is considered stale and pruned,
    /// guarding against a badge stuck on red if a "done" event is ever missed.
    public static let defaultTTL: TimeInterval = 30 * 60

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-signaller", isDirectory: true)
        self.root = base
        self.sessionsDir = base.appendingPathComponent("sessions", isDirectory: true)
    }

    public func ensureDir() throws {
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    private func fileURL(for id: String) -> URL {
        // Sanitize the id so it is always a safe single path component.
        let safe = id.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "-" || c == "_" { return c }
            return "_"
        }
        let name = String(safe).isEmpty ? "unknown" : String(safe)
        return sessionsDir.appendingPathComponent("\(name).json")
    }

    /// Create or update a session's status. Atomic write. Terminal-identity
    /// fields are preserved from the existing record when the new value is nil
    /// (so a later Stop hook that didn't re-capture them keeps the tab handle).
    public func upsert(id: String, tool: AgentTool, state: AgentState, cwd: String, now: Double,
                       termProgram: String? = nil, termSessionId: String? = nil, tty: String? = nil,
                       transcriptPath: String? = nil, title: String? = nil) throws {
        try ensureDir()
        let url = fileURL(for: id)
        let existing: Session? = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(Session.self, from: $0)
        }
        let session = Session(
            tool: tool, state: state, cwd: cwd, updated: now,
            termProgram: termProgram ?? existing?.termProgram,
            termSessionId: termSessionId ?? existing?.termSessionId,
            tty: tty ?? existing?.tty,
            transcriptPath: transcriptPath ?? existing?.transcriptPath,
            title: title ?? existing?.title)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(session)
        try data.write(to: url, options: .atomic)
    }

    /// Live (non-stale) sessions sorted by id for stable display ordering.
    public func liveSorted(now: Double, ttl: TimeInterval = SessionStore.defaultTTL) -> [(id: String, session: Session)] {
        all().filter { now - $0.session.updated <= ttl }
            .sorted { $0.id < $1.id }
    }

    /// Remove a session (e.g. on SessionEnd).
    public func remove(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    /// All current sessions keyed by id (file basename without extension).
    public func all() -> [(id: String, session: Session)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        var out: [(String, Session)] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? decoder.decode(Session.self, from: data) else { continue }
            out.append((url.deletingPathExtension().lastPathComponent, s))
        }
        return out
    }

    /// Delete sessions older than `ttl`. Returns number pruned.
    @discardableResult
    public func gc(now: Double, ttl: TimeInterval = SessionStore.defaultTTL) -> Int {
        var pruned = 0
        for (id, s) in all() where now - s.updated > ttl {
            remove(id: id)
            pruned += 1
        }
        return pruned
    }

    /// The set of ttys (e.g. "ttys001") that currently have a running process,
    /// via `ps`. An empty result means the lookup failed (caller should not
    /// prune in that case).
    public static func activeTTYs() -> Set<String> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "tty="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Set(out.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Normalize a stored tty ("/dev/ttys001") to ps form ("ttys001").
    public static func normalizeTTY(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    /// Aggregate state across all (non-stale) sessions.
    /// Returns nil when there are no live sessions (idle).
    public func aggregate(now: Double, ttl: TimeInterval = SessionStore.defaultTTL) -> AgentState? {
        let live = all().map { $0.session }.filter { now - $0.updated <= ttl }
        return live.max(by: { $0.state.rank < $1.state.rank })?.state
    }
}
