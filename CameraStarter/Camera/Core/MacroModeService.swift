//
//  MacroModeService.swift
//  CameraStarter
//
//  Provides macro mode detection and camera switching functionality
//

import AVFoundation


/// Action to take based on macro conditions
enum MacroAction {
    case none
    case activate  // Immediately activate (after user manual tap)
    case deactivate(reason: String)
}

/// Service for macro mode detection and activation
@MainActor
@Observable
final class MacroModeService {

    // MARK: - Public Properties

    /// Whether auto macro switching is enabled (user setting)
    var isAutoMacroEnabled: Bool = true

    /// Whether currently in macro mode (using Ultra Wide camera)
    private(set) var isMacroModeActive: Bool = false

    /// Whether in macro focus range (for showing macro indicator)
    private(set) var isInMacroFocusRange: Bool = false

    /// Whether macro activation is suggested (for showing button and toast)
    private(set) var isMacroSuggested: Bool = false

    // MARK: - Private Properties

    private let config = CameraConfiguration.shared

    /// Whether user manually disabled macro (when auto-trigger conditions were met)
    private var isMacroManuallyDisabled: Bool = false

    /// Zoom factor before entering macro mode (for restoring on exit)
    private var preMacroZoomFactor: CGFloat

    /// Macro detection stable count
    private var macroDetectionCount: Int = 0

    /// Focus search count (for detecting main camera inability to focus)
    private var focusSearchCount: Int = 0

    /// Macro mode focus hunting counter (detecting continuous instability)
    private var macroFocusHuntingCount: Int = 0

    // MARK: - Initialization

    init() {
        self.preMacroZoomFactor = config.zoom.defaultBackCameraZoom
    }

    // MARK: - Public Methods

    /// Manually toggles macro mode (called when user taps macro icon)
    func toggleManualMode() -> Bool {
        if isMacroModeActive {
            // Currently in macro mode → manually exit
            isMacroManuallyDisabled = true
            isMacroSuggested = false
            return false  // Signal to deactivate
        } else {
            // Currently not in macro mode → manually enter
            isMacroManuallyDisabled = false
            isMacroSuggested = false
            return true  // Signal to activate
        }
    }

    /// Dismisses macro suggestion (called when user ignores the toast)
    func dismissSuggestion() {
        isMacroSuggested = false
        isMacroManuallyDisabled = true
    }

    /// Checks macro condition per frame (called from video delegate)
    /// - Parameters:
    ///   - lensPosition: Current lens position (0.0 = infinity, 1.0 = minimum focus)
    ///   - isAdjustingFocus: Whether camera is adjusting focus
    ///   - currentZoom: Current zoom factor
    ///   - isBackCamera: Whether using back camera
    ///   - hasUltraWide: Whether Ultra Wide camera is available
    /// - Returns: Action to take
    func checkConditions(
        lensPosition: Float,
        isAdjustingFocus: Bool,
        currentZoom: CGFloat,
        isBackCamera: Bool,
        hasUltraWide: Bool
    ) -> MacroAction {
        // Check prerequisites
        guard isAutoMacroEnabled else {
            return .none
        }
        guard isBackCamera else {
            return .none
        }
        guard hasUltraWide else {
            return .none
        }

        let isMainCamera = currentZoom >= config.zoom.defaultBackCameraZoom
        let needsMacro = lensPosition < config.macro.macroCheckThreshold

        // Update indicator state (should show when macro mode is active)
        // This syncs the UI indicator with the actual macro mode state
        let shouldShowIndicator = isMacroModeActive
        if isInMacroFocusRange != shouldShowIndicator {
            isInMacroFocusRange = shouldShowIndicator
        }


        if !isMacroModeActive {
            return checkActivationConditions(
                isMainCamera: isMainCamera,
                needsMacro: needsMacro,
                lensPosition: lensPosition,
                isAdjustingFocus: isAdjustingFocus
            )
        } else {
            return checkDeactivationConditions(
                lensPosition: lensPosition,
                isAdjustingFocus: isAdjustingFocus
            )
        }
    }

    /// Updates macro mode activation state
    func setActive(_ active: Bool, preMacroZoom: CGFloat? = nil) {
        self.isMacroModeActive = active
        // Note: isInMacroFocusRange is updated in checkConditions() each frame

        if active {
            if let zoom = preMacroZoom {
                self.preMacroZoomFactor = zoom
            }
            self.macroDetectionCount = 0
            self.isMacroSuggested = false  // Clear suggestion state after activation
        } else {
            self.macroDetectionCount = 0
            self.focusSearchCount = 0
            self.macroFocusHuntingCount = 0
            self.isMacroSuggested = false  // Clear suggestion state on exit
        }
    }

    /// Gets pre-macro zoom factor (for restoration)
    func getPreMacroZoom() -> CGFloat {
        return self.preMacroZoomFactor
    }

    /// Resets macro state (for camera switch or app restart)
    func resetState() {
        if self.isMacroModeActive || self.isInMacroFocusRange || self.isMacroSuggested || self.isMacroManuallyDisabled {
            self.isMacroModeActive = false
            self.isInMacroFocusRange = false
            self.isMacroSuggested = false
            self.isMacroManuallyDisabled = false  // Reset manual disable flag
            self.macroDetectionCount = 0
            self.focusSearchCount = 0
            self.macroFocusHuntingCount = 0  // Also reset hunting count
        }
    }

    // MARK: - Private Methods (Activation Logic)

    private func checkActivationConditions(
        isMainCamera: Bool,
        needsMacro: Bool,
        lensPosition: Float,
        isAdjustingFocus: Bool
    ) -> MacroAction {
        // If user manually disabled macro, don't auto re-enable
        if isMacroManuallyDisabled {
            // Reset manual disable flag when distance returns to normal
            if !needsMacro {
                isMacroManuallyDisabled = false
            }
            return .none
        }

        if isMainCamera && needsMacro {
            // Condition satisfied: increment count
            focusSearchCount += 1

            if self.focusSearchCount >= self.config.macro.focusSearchThreshold {
                self.isMacroSuggested = true
            }
        } else {
            // Conditions no longer satisfied (distance returns to normal or switched to non-main camera)

            // Gradually decrement count (when on main camera)
            if isMainCamera && focusSearchCount > 0 {
                focusSearchCount = max(0, focusSearchCount - 1)
            } else if !isMainCamera {
                // Switched to non-main camera, clear immediately
                focusSearchCount = 0
            }

            // FIX: Regardless of count, clear suggestion state if conditions not met and suggestion still active
            if isMacroSuggested {
                isMacroSuggested = false
            }
        }

        return .none
    }

    // MARK: - Private Methods (Deactivation Logic)

    private func checkDeactivationConditions(
        lensPosition: Float,
        isAdjustingFocus: Bool
    ) -> MacroAction {
        // Strategy 1a: Too close (lens > threshold) → guide user to maintain proper distance
        let tooClose = lensPosition > config.macro.tooCloseThreshold && !isAdjustingFocus

        if tooClose {
            macroDetectionCount += 1
            if macroDetectionCount >= config.macro.stableThreshold {
                return .deactivate(reason: "too close")
            }
            return .none  // Early exit
        }

        // Strategy 1b: Focus completely lost (object suddenly removed or moved very far)
        let focusLost = lensPosition < config.macro.focusLostThreshold && !isAdjustingFocus

        if focusLost {
            macroDetectionCount += 1
            if macroDetectionCount >= config.macro.stableThreshold {
                return .deactivate(reason: "focus lost")
            }
            return .none  // Early exit
        } else {
            macroDetectionCount = 0
        }

        // Strategy 2: Detect continuous focus hunting (most accurate exit signal)
        if isAdjustingFocus {
            // Only count hunting when lens value is low (indicating "too far" instability)
            // lens > huntingLensThreshold hunting might be "too close", should keep macro
            if lensPosition < config.macro.huntingLensThreshold {
                macroFocusHuntingCount += 1

                // Continuous hunting exceeds threshold (~2s) → distance may not suit macro
                if macroFocusHuntingCount >= config.macro.huntingExitThreshold {
                    return .deactivate(reason: "focus hunting")
                }
            } else {
                // lens > huntingLensThreshold hunting: might be too close, slowly decay count
                macroFocusHuntingCount = max(0, macroFocusHuntingCount - 1)
            }
        } else {
            // Focus stabilized, quickly decay hunting count (give second chance)
            macroFocusHuntingCount = max(0, macroFocusHuntingCount - 3)
        }

        return .none
    }
}
