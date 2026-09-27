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

        /// Delay before auto-enabling portrait mode (synced with bounding box fade-out)
        let autoEnableDelay: TimeInterval = 2.0

        /// Minimum zoom for hardware depth support (device zoom factor)
        let minZoomForHardwareDepth: CGFloat = 1.8

        /// Maximum zoom for hardware depth support (device zoom factor)
        let maxZoomForHardwareDepth: CGFloat = 7.0
    }

    // MARK: - Macro Mode Settings

    struct MacroMode {
        /// Lens position threshold for triggering macro mode (0.0 = infinity, 1.0 = minimum focus distance)
        /// When lensPosition > 0.85, the main camera is trying to focus very close
        let lensPositionThreshold: Float = 0.85

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

        // MARK: - Front Camera Selfie Settings (Native Camera Style)

        /// Front camera zoom range (device zoom factors)
        /// Range: 1.0 (widest) to 2.0 (standard portrait framing)
        let frontCameraMinZoom: CGFloat = 1.0
        let frontCameraMaxZoom: CGFloat = 2.0

        /// Front camera default zoom (slightly zoomed for better framing)
        let frontCameraDefaultZoom: CGFloat = 1.0
    }

    // MARK: - Focus Settings

    struct Focus {
        /// Delay before capture (iOS Responsive Capture handles focus stabilization)
        /// Set to 0 for zero shutter lag - the system uses buffered frames
        let lockDelayBeforeCapture: TimeInterval = 0
    }

    // MARK: - Transition Settings

    struct Transition {
        /// Duration of camera switch animation
        let switchAnimationDuration: TimeInterval = 0.2

        /// Delay before fading out snapshot overlay
        let snapshotFadeDelay: TimeInterval = 0.35
    }

    // MARK: - Photo Settings

    struct Photo {
        /// Thumbnail size for preview
        let thumbnailSize: (width: Int, height: Int) = (256, 256)

        /// Preferred photo codec
        let preferredCodec: String = "hevc"  // AVVideoCodecType.hevc
    }

    // MARK: - Timer Settings

    struct Timer {
        /// Available timer durations in seconds
        let availableDurations: [Int] = [3, 5, 10]

        /// Countdown update interval
        let updateInterval: TimeInterval = 1.0

        /// Seconds before capture to start haptic feedback
        let hapticFeedbackStartSeconds: Int = 3
    }

    // MARK: - Singleton Instance

    let portrait = PortraitMode()
    let macro = MacroMode()
    let zoom = Zoom()
    let focus = Focus()
    let transition = Transition()
    let photo = Photo()
    let timer = Timer()

    /// Shared configuration instance
    static let shared = CameraConfiguration()
}
