import Foundation
import SignalerCore

/// Polls the session store on a short interval and reports the live session list
/// whenever it changes. Polling (rather than FSEvents) is used deliberately: it
/// is simple, robust against atomic-rename quirks, and also drives periodic GC.
/// The update rate is well within the "glanceable, ~1s" requirement.
final class Watcher {
    private let store = SessionStore()
    private let onChange: ([(id: String, session: Session)]) -> Void
    private var timer: Timer?
    private var lastSignature: String?
    private var tick = 0

    private let interval: TimeInterval = 0.4
    private let gcEveryNTicks = 150  // ~ every 60s

    /// Seconds of transcript silence before a stuck "working" session is hidden.
    /// Override with: defaults write mobile.pure.agent-signaller workingStaleSeconds <n>
    private var staleWorkingSeconds: TimeInterval {
        let v = UserDefaults.standard.object(forKey: "workingStaleSeconds") as? Double
        return v ?? SessionStore.defaultWorkingStaleSeconds
    }

    init(onChange: @escaping ([(id: String, session: Session)]) -> Void) {
        self.onChange = onChange
    }

    func current() -> [(id: String, session: Session)] {
        store.liveActive(now: Date().timeIntervalSince1970, staleWorkingSeconds: staleWorkingSeconds)
    }

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
        let list = store.liveActive(now: now, staleWorkingSeconds: staleWorkingSeconds)
        let sig = signature(list)
        if sig == lastSignature { return }
        lastSignature = sig
        onChange(list)
    }
}
