//
//  ContinuousFocusController.swift
//  CameraStarter
//
//  Enhanced focus controller for subject lock
//  Provides continuous autofocus on tracked subject with smooth updates
//
//  Key features:
//  - Continuous AF on tracked subject ROI
//  - Smooth focus point transitions (prevents hunting)
//  - Focus state monitoring
//  - Integration with LiDAR/depth when available
//

import AVFoundation
import CoreGraphics
import os.log

/// Focus update result
enum FocusUpdateResult {
    case success
    case notSupported
    case deviceBusy
    case error(Error)
}

/// Continuous focus controller for subject tracking
/// Note: This class operates on AVCaptureDevice and should be called from the session queue
final class ContinuousFocusController {

    private let logger = Logger(subsystem: Log.subsystem, category: "ContinuousFocus")

    // MARK: - Configuration

    /// Minimum distance to trigger focus update (normalized coordinates)
    private let minFocusUpdateDistance: CGFloat = 0.015  // 1.5% of screen

    /// Smoothing factor for focus point (0-1, higher = faster response)
    private let focusSmoothingFactor: CGFloat = 0.4

    /// Minimum interval between focus updates (seconds)
    private let minFocusInterval: TimeInterval = 0.05  // 20Hz max

    // MARK: - State

    /// Current smoothed focus point
    private var currentFocusPoint: CGPoint?

    /// Last time focus was updated
    private var lastFocusUpdateTime: Date?

    // MARK: - Public Methods

    /// Update focus point for tracked subject
    /// Returns result indicating success or failure reason
    @discardableResult
    func updateFocusPoint(_ point: CGPoint, on device: AVCaptureDevice) -> FocusUpdateResult {
        guard device.isFocusPointOfInterestSupported else {
            return .notSupported
        }

        // Throttle updates
        if let lastUpdate = lastFocusUpdateTime {
            let elapsed = Date().timeIntervalSince(lastUpdate)
            if elapsed < minFocusInterval {
                return .deviceBusy
            }
        }

        // Smooth the focus point
        let smoothedPoint: CGPoint
        if let current = currentFocusPoint {
            smoothedPoint = CGPoint(
                x: current.x + (point.x - current.x) * focusSmoothingFactor,
                y: current.y + (point.y - current.y) * focusSmoothingFactor
            )

            // Check if movement is significant enough
            let distance = hypot(smoothedPoint.x - current.x, smoothedPoint.y - current.y)
            if distance < minFocusUpdateDistance {
                return .success  // No update needed, still success
            }
        } else {
            smoothedPoint = point
        }

        // Clamp to valid range
        let clampedPoint = CGPoint(
            x: min(1, max(0, smoothedPoint.x)),
            y: min(1, max(0, smoothedPoint.y))
        )

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // Save current zoom (focus shouldn't affect zoom)
            let currentZoom = device.videoZoomFactor

            // Update focus point of interest
            device.focusPointOfInterest = clampedPoint

            // Ensure we're in continuous mode
            if device.focusMode != .continuousAutoFocus {
                device.focusMode = .continuousAutoFocus
            }

            // Also update exposure point
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clampedPoint
            }

            // Restore zoom
            device.videoZoomFactor = currentZoom

            currentFocusPoint = clampedPoint
            lastFocusUpdateTime = Date()

            return .success
        } catch {
            logger.error("Failed to update focus point: \(error.localizedDescription)")
            return .error(error)
        }
    }

}
