//
//  PortraitModeService.swift
//  CameraStarter
//
//  Provides portrait mode detection and activation functionality
//

import Foundation


/// Service for portrait mode conditions and automatic activation
@MainActor
@Observable
final class PortraitModeService {

    // MARK: - Public Properties

    /// Current capture mode
    var captureMode: CaptureMode = .photo {
        didSet {
            if self.captureMode != oldValue {
                onCaptureModeChanged?(self.captureMode)
            }
        }
    }

    /// Callback when capture mode changes (for notifying CameraManager)
    var onCaptureModeChanged: ((CaptureMode) -> Void)?

    /// Whether portrait conditions are stably satisfied (readable from outside)
    private(set) var isPortraitConditionStable = false

    // MARK: - Private Properties

    private let config = CameraConfiguration.shared
    private let portraitConditionDetector = PortraitConditionDetector()

    /// Portrait condition consecutive satisfied count
    private var portraitSatisfiedCount: Int = 0

    /// Portrait condition consecutive unsatisfied count
    private var portraitUnsatisfiedCount: Int = 0

    /// Cooldown time after manual disable (prevents immediate re-enable)
    private var manualDisableCooldownUntil: Date?

    /// Cooldown duration (seconds)
    private let manualDisableCooldown: TimeInterval = 3.0

    // MARK: - Dependency Injection

    /// Closure to check if device supports depth capability
    var checkDepthCapability: () -> Bool = { true }

    // MARK: - Public Methods

    /// Updates portrait conditions based on subject detection
    /// - Parameters:
    ///   - subjectDetections: Detected subjects
    ///   - salientObject: Salient object bounding box
    ///   - currentZoom: Current UI zoom level
    func updateConditions(
        subjectDetections: [SubjectDetectionResult],
        salientObject: CGRect?,
        currentZoom: CGFloat
    ) {
        let hasDepthCapability = checkDepthCapability()

        let condition = portraitConditionDetector.checkConditions(
            subjectDetections: subjectDetections,
            salientObject: salientObject,
            currentZoom: currentZoom,
            hasDepthCapability: hasDepthCapability
        )

        // Stability control
        if condition.isSatisfied {
            portraitSatisfiedCount += 1
            portraitUnsatisfiedCount = 0

            // Conditions stably satisfied → immediately enable portrait mode
            if portraitSatisfiedCount >= config.portrait.stableThreshold {
                // Only attempt to enable when not in cooldown period
                if !isPortraitConditionStable && !isInCooldown {
                    isPortraitConditionStable = true
                    // Immediately enable Portrait mode, no longer wait for delay
                    setPortraitMode(enabled: true)
                }
                // If in cooldown period, don't set isPortraitConditionStable, wait for cooldown to end before trying
            }
        } else {
            portraitUnsatisfiedCount += 1
            // No longer reset satisfiedCount, let it persist
            // Only reset when consecutive unsatisfied count reaches gracePeriod

            // Conditions no longer satisfied → exit portrait mode
            if portraitUnsatisfiedCount >= config.portrait.gracePeriod && isPortraitConditionStable {
                isPortraitConditionStable = false
                portraitSatisfiedCount = 0  // Only reset when actually disabling

                if captureMode == .portrait {
                    captureMode = .photo
                }
            }
        }
    }

    /// Disables portrait mode (called when macro mode activates)
    func disablePortraitMode() {
        if captureMode == .portrait {
            captureMode = .photo
            isPortraitConditionStable = false
        }
    }

    /// Manually disable Portrait mode (user taps button)
    func manuallyDisablePortraitMode() {
        if captureMode == .portrait {
            captureMode = .photo
            manualDisableCooldownUntil = Date().addingTimeInterval(manualDisableCooldown)
        }
    }

    // MARK: - Private Methods

    /// Check if in cooldown period (includes manual disable and motion disable)
    private var isInCooldown: Bool {
        let now = Date()

        // Check manual disable cooldown
        if let manualCooldown = manualDisableCooldownUntil, now < manualCooldown {
            return true
        }

        return false
    }

    /// Enables/disables portrait mode (internal automatic control)
    private func setPortraitMode(enabled: Bool) {
        guard enabled != (captureMode == .portrait) else { return }

        if enabled {
            // Check cooldown time
            if isInCooldown {
                return
            }
            captureMode = .portrait
        } else {
            captureMode = .photo
        }
    }
}
