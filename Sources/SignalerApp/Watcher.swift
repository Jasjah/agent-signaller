import Foundation
import SignalerCore

/// Polls the session store on a short interval and reports the live session list
/// whenever it changes. Polling (rather than FSEvents) is used deliberately: it
/// is simple, robust against atomic-rename quirks, and also drives periodic GC.
/// The update rate is well within the "glanceable, ~1s" requirement.
///
/// We intentionally do NOT auto-clear a "working" session on a timer: Claude Code
/// gives no signal during a long-running tool, so a timer can't tell "still
/// working" from "interrupted" and would falsely turn the dot green mid-work.
/// A session stays working until Stop (→done), a new prompt, or the stale GC.
final class Watcher {
    private let store = SessionStore()
    private let onChange: ([(id: String, session: Session)]) -> Void
    private var timer: Timer?
    private var lastSignature: String?
    private var tick = 0

    private let interval: TimeInterval = 0.4
    private let gcEveryNTicks = 150     // ~ every 60s
    private let ttyCheckEveryNTicks = 12 // ~ every 5s — clear dots for closed terminals
    // Session ids whose terminal we've confirmed alive at least once. We only
    // prune a session on close if it was previously seen alive — so a session
    // whose captured tty we can't match (e.g. Codex's transient hook tty) is
    // never falsely cleared while still open.
    private var seenAlive = Set<String>()

    init(onChange: @escaping ([(id: String, session: Session)]) -> Void) {
        self.onChange = onChange
    }

    func current() -> [(id: String, session: Session)] {
        store.liveSorted(now: Date().timeIntervalSince1970)
    }

    func start() {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Remove sessions whose terminal was closed — but only ones we previously
    /// confirmed alive, so an unmatched/transient tty never falsely clears an
    /// open session.
    private func pruneClosedTerminals() {
        let active = SessionStore.activeTTYs()
        guard !active.isEmpty else { return }  // lookup failed → don't touch anything
        for (id, s) in store.all() {
            guard let tty = s.tty, !tty.isEmpty else { continue }
            if active.contains(SessionStore.normalizeTTY(tty)) {
                seenAlive.insert(id)
            } else if seenAlive.contains(id) {
                store.remove(id: id)   // was alive, terminal now gone → closed
                seenAlive.remove(id)
            }
            // else: never confirmed alive → untrusted tty, leave to the GC
        }
    }

    private func signature(_ list: [(id: String, session: Session)]) -> String {
        let sessions = list.map { "\($0.id):\($0.session.state.rawValue)" }.joined(separator: "|")
        return sessions + "|style:" + store.readStyle().rawValue  // re-render on style change too
    }

    private func poll() {
        let now = Date().timeIntervalSince1970
        tick += 1
        if tick % gcEveryNTicks == 0 {
            store.gc(now: now)
        }
        if tick % ttyCheckEveryNTicks == 0 {
            pruneClosedTerminals()  // drop dots whose terminal was closed
        }
        let list = store.liveSorted(now: now)
        let sig = signature(list)
        if sig == lastSignature { return }
        lastSignature = sig
        onChange(list)
    }
}
