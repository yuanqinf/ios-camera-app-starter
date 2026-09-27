//
//  CameraTimerManager.swift
//  CameraStarter
//
//  Camera timer manager for countdown capture
//

import Foundation


/// Timer duration options
enum TimerDuration: Int, CaseIterable {
    case off = 0
    case three = 3
    case five = 5
    case ten = 10

    /// Display text for the timer button
    var displayText: String {
        switch self {
        case .off: return String(localized: "Off")
        case .three: return String(localized: "3s", comment: "Self-timer duration: 3 seconds")
        case .five: return String(localized: "5s", comment: "Self-timer duration: 5 seconds")
        case .ten: return String(localized: "10s", comment: "Self-timer duration: 10 seconds")
        }
    }

    /// Cycle to next duration
    var next: TimerDuration {
        switch self {
        case .off: return .three
        case .three: return .five
        case .five: return .ten
        case .ten: return .off
        }
    }
}

/// Camera timer state
enum TimerState {
    case idle
    case counting(remaining: Int)
    case capturing
}

/// Manager for camera countdown timer
@Observable
final class CameraTimerManager {
    // MARK: - Public Properties

    /// Current timer duration setting
    private(set) var duration: TimerDuration = .off

    /// Current timer state
    private(set) var state: TimerState = .idle

    /// Remaining seconds in countdown
    var remainingSeconds: Int {
        switch state {
        case .idle, .capturing:
            return 0
        case .counting(let remaining):
            return remaining
        }
    }

    /// Whether timer is currently counting down
    var isCountingDown: Bool {
        if case .counting = state {
            return true
        }
        return false
    }

    /// Whether timer is enabled (duration > 0)
    var isEnabled: Bool {
        duration != .off
    }

    // MARK: - Private Properties

    private var countdownTimer: Timer?
    private var captureCallback: (() -> Void)?

    /// Work items for cancellable scheduled tasks
    private var captureWorkItem: DispatchWorkItem?
    private var resetWorkItem: DispatchWorkItem?

    // MARK: - Public Methods

    /// Cycle to next timer duration
    func cycleDuration() {
        // Cancel any active countdown when changing duration
        cancelCountdown()
        duration = duration.next
    }

    /// Start countdown timer
    /// - Parameter onCapture: Callback to execute when countdown completes
    func startCountdown(onCapture: @escaping () -> Void) {
        guard duration != .off else {
            // No timer, capture immediately
            onCapture()
            return
        }

        // Cancel any existing countdown
        cancelCountdown()

        // Store callbacks
        captureCallback = onCapture

        // Start countdown
        let seconds = duration.rawValue
        state = .counting(remaining: seconds)

        // Create repeating timer
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            switch self.state {
            case .counting(let remaining):
                if remaining <= 1 {
                    // Last second - capture at 1.0s
                    timer.invalidate()
                    self.countdownTimer = nil

                    // Update state to show 0
                    self.state = .counting(remaining: 0)

                    // Capture after full 1 second (cancellable)
                    let captureWork = DispatchWorkItem { [weak self] in
                        guard let self, self.isCountingDown else { return }
                        self.state = .capturing

                        // Execute capture callback
                        self.captureCallback?()
                        self.captureCallback = nil

                        // Reset state after brief delay (cancellable)
                        let resetWork = DispatchWorkItem { [weak self] in
                            self?.state = .idle
                        }
                        self.resetWorkItem = resetWork
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: resetWork)
                    }
                    self.captureWorkItem = captureWork
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: captureWork)
                } else {
                    // Decrement countdown
                    self.state = .counting(remaining: remaining - 1)
                }
            default:
                timer.invalidate()
                self.countdownTimer = nil
            }
        }
    }

    /// Cancel active countdown
    func cancelCountdown() {
        // Cancel timer
        countdownTimer?.invalidate()
        countdownTimer = nil

        // Cancel all scheduled work items
        captureWorkItem?.cancel()
        captureWorkItem = nil
        resetWorkItem?.cancel()
        resetWorkItem = nil

        // Clear callbacks
        captureCallback = nil

        if isCountingDown {
        }

        state = .idle
    }

    deinit {
        cancelCountdown()
    }
}
