import Combine
import Foundation

enum FocusTimerPhase: Hashable {
    case idle
    case running
    case paused
}

struct FocusTimerCompletion {
    let category: String
    let sessionNames: [String]
    let note: String
    let elapsedSeconds: Int
    let collectDetailsAfterTimer: Bool
    let reachedZero: Bool
}

@MainActor
final class FocusTimerModel: ObservableObject {
    @Published private(set) var phase: FocusTimerPhase = .idle
    @Published private(set) var remainingSeconds: Int
    @Published private(set) var durationMinutes: Int
    @Published var category = ""
    @Published var sessionNames: [String] = []
    @Published var note = ""
    @Published private(set) var statusMessage = "Ready"

    var onTick: (() -> Void)?
    var onStateChange: (() -> Void)?
    var onComplete: ((FocusTimerCompletion) -> Void)?

    private var ticker: Timer?
    private var collectDetailsAfterTimer = false

    init(defaultMinutes: Int) {
        let minutes = max(1, defaultMinutes)
        durationMinutes = minutes
        remainingSeconds = minutes * 60
    }

    var totalSeconds: Int { durationMinutes * 60 }
    var isActive: Bool { phase != .idle }

    func setDurationMinutes(_ minutes: Int) {
        guard phase == .idle else { return }
        durationMinutes = min(720, max(1, minutes))
        remainingSeconds = totalSeconds
        statusMessage = "Ready"
        onStateChange?()
    }

    func startFromWindow() {
        collectDetailsAfterTimer = false
        startOrResume()
    }

    func startFromMenu(category: String) {
        guard phase == .idle else { return }
        self.category = category
        sessionNames = []
        note = ""
        collectDetailsAfterTimer = true
        startOrResume()
    }

    func startOrResume() {
        guard !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if phase == .idle, remainingSeconds <= 0 { remainingSeconds = totalSeconds }
        phase = .running
        statusMessage = "Focusing"
        scheduleTicker()
        onStateChange?()
    }

    func pause() {
        guard phase == .running else { return }
        ticker?.invalidate()
        ticker = nil
        phase = .paused
        statusMessage = "Paused"
        onStateChange?()
    }

    func restart() {
        guard phase != .idle else { return }
        ticker?.invalidate()
        remainingSeconds = totalSeconds
        phase = .running
        statusMessage = "Restarted"
        scheduleTicker()
        onStateChange?()
    }

    func cancel() {
        ticker?.invalidate()
        ticker = nil
        phase = .idle
        remainingSeconds = totalSeconds
        collectDetailsAfterTimer = false
        statusMessage = "Cancelled"
        onStateChange?()
    }

    func finishNow() {
        guard phase != .idle else { return }
        complete(reachedZero: false)
    }

    private func scheduleTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        guard phase == .running else { return }
        remainingSeconds = max(0, remainingSeconds - 1)
        onTick?()
        if remainingSeconds == 0 { complete(reachedZero: true) }
    }

    private func complete(reachedZero: Bool) {
        ticker?.invalidate()
        ticker = nil
        let completion = FocusTimerCompletion(
            category: category.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionNames: sessionNames,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            elapsedSeconds: max(0, totalSeconds - remainingSeconds),
            collectDetailsAfterTimer: collectDetailsAfterTimer,
            reachedZero: reachedZero
        )
        phase = .idle
        remainingSeconds = totalSeconds
        collectDetailsAfterTimer = false
        statusMessage = reachedZero ? "Session completed" : "Session saved"
        onStateChange?()
        onComplete?(completion)
    }
}
