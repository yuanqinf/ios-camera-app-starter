//
//  CameraConfiguration.swift
//  CameraStarter
//
//  Camera configuration constants
//

import Foundation

/// Camera system configuration
struct CameraConfiguration {

    // MARK: - Portrait Mode Settings

    struct PortraitMode {
        /// Number of consecutive frames needed to consider portrait conditions stable
        let stableThreshold: Int = 1  // Instant enable (1 frame = ~33ms, zero-latency response)

        /// Number of consecutive frames where conditions must be unsatisfied before disabling
        let gracePeriod: Int = 10  // 10 frames * ~100ms = ~1s

        /// Minimum zoom for hardware depth support (device zoom factor)
        let minZoomForHardwareDepth: CGFloat = 1.8

        /// Maximum zoom for hardware depth support (device zoom factor)
        let maxZoomForHardwareDepth: CGFloat = 7.0
    }

    // MARK: - Macro Mode Settings

    struct MacroMode {
        /// Number of consecutive detections needed to activate macro mode
        let stableThreshold: Int = 10  // ~500ms at 30fps

        /// Number of consecutive frames where focus search occurs before triggering macro
        let focusSearchThreshold: Int = 15  // ~0.75s at 30fps

        /// Threshold for detecting "too close" in macro mode
        let tooCloseThreshold: Float = 0.75

        /// Threshold for detecting "focus lost" in macro mode
        let focusLostThreshold: Float = 0.10

        /// Lens position threshold for focus hunting detection
        let huntingLensThreshold: Float = 0.60

        /// Consecutive hunting frames before exiting macro
        let huntingExitThreshold: Int = 40  // ~2s at 30fps

        /// Lens position threshold for macro mode check
        let macroCheckThreshold: Float = 0.20

        /// Ultra Wide zoom factor for macro mode
        let ultraWideZoomFactor: CGFloat = 2.0
    }

    // MARK: - Zoom Settings

    struct Zoom {
        /// Default zoom factor for back camera (Triple Camera main sensor)
        let defaultBackCameraZoom: CGFloat = 2.0

        /// Default zoom factor for front camera
        let defaultFrontCameraZoom: CGFloat = 1.0

        /// Fixed preset zoom levels for back camera (UI display)
        let presetZoomLevels: [CGFloat] = [0.5, 1.0, 2.0, 3.0]
    }

    // MARK: - Transition Settings

    struct Transition {
        /// Duration of camera switch animation
        let switchAnimationDuration: TimeInterval = 0.2

        /// Delay before fading out snapshot overlay
        let snapshotFadeDelay: TimeInterval = 0.35
    }

    // MARK: - Singleton Instance

    let portrait = PortraitMode()
    let macro = MacroMode()
    let zoom = Zoom()
    let transition = Transition()

    /// Shared configuration instance
    static let shared = CameraConfiguration()
}
