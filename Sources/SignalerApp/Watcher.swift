import Foundation
import SignalerCore

/// Polls the session store on a short interval and reports the live session list
/// whenever it changes. Polling (rather than FSEvents) is used deliberately: it
/// is simple, robust against atomic-rename quirks, and also drives periodic GC.
/// The update rate is well within the "glanceable, ~1s" requirement.
final class Watcher {
    private let store = SessionStore()
    // Reports (sessions, staleIds): staleIds are sessions shown as done only
    // because their work went quiet (interrupt), so the chime is suppressed.
    private let onChange: ([(id: String, session: Session)], Set<String>) -> Void
    private var timer: Timer?
    private var lastSignature: String?
    private var tick = 0

    private let interval: TimeInterval = 0.4
    private let gcEveryNTicks = 150  // ~ every 60s

    /// Seconds of transcript silence before a stuck "working" session is shown
    /// as done (Claude Code fires no hook on interrupt).
    /// Override with: defaults write mobile.pure.agent-signaller workingStaleSeconds <n>
    private var staleWorkingSeconds: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "workingStaleSeconds") as? Double
        return v ?? SessionStore.defaultWorkingStaleSeconds
    }

    init(onChange: @escaping ([(id: String, session: Session)], Set<String>) -> Void) {
        self.onChange = onChange
    }

    /// Live sessions with stuck "working" entries shown as done (dot stays, turns
    /// green) rather than hidden. Returns the displayed list plus the ids that
    /// were force-completed by staleness.
    private func snapshot() -> ([(id: String, session: Session)], Set<String>) {
        let now = Date().timeIntervalSince1970
        var stale = Set<String>()
        let list = store.liveSorted(now: now).map { entry -> (id: String, session: Session) in
            if entry.session.state == .working,
               !store.isActive(entry.session, now: now, staleWorkingSeconds: staleWorkingSeconds) {
                stale.insert(entry.id)
                var s = entry.session
                s.state = .done
                return (entry.id, s)
            }
            return entry
        }
        return (list, stale)
    }

    func current() -> [(id: String, session: Session)] { snapshot().0 }

    func start() {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func signature(_ list: [(id: String, session: Session)]) -> String {
        list.map { "\($0.id):\($0.session.state.rawValue)" }.joined(separator: "|")
    }

    private func poll() {
        let now = Date().timeIntervalSince1970
        tick += 1
        if tick % gcEveryNTicks == 0 {
            store.gc(now: now)
        }
        let (list, stale) = snapshot()
        let sig = signature(list)
        if sig == lastSignature { return }
        lastSignature = sig
        onChange(list, stale)
    }
}
