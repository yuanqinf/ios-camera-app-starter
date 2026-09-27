//
//  FocusControl.swift
//  CameraStarter
//
//  Focus control module - Simplified version
//  Single point focus, used with SubjectDetector
//

import AVFoundation
import CoreGraphics
import os.log

/// Focus control
final class FocusControl {

    private let logger = Logger(subsystem: Log.subsystem, category: "FocusControl")

    /// Focus at specified point
    /// - Parameters:
    ///   - point: Focus point (device coordinate system, 0-1 range)
    ///   - device: Camera device
    func focus(at point: CGPoint, on device: AVCaptureDevice) {
        guard device.isFocusPointOfInterestSupported,
              device.isFocusModeSupported(.continuousAutoFocus) else {
            logger.warning("Focus at point not supported on this device")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // Save current zoom level (focus shouldn't change zoom)
            let currentZoom = device.videoZoomFactor

            // Set focus point
            device.focusPointOfInterest = point

            // Use continuousAutoFocus: start continuous focus at specified point
            // This way focus will continue tracking after completion, won't stop
            device.focusMode = .continuousAutoFocus

            // Ensure zoom level remains unchanged
            device.videoZoomFactor = currentZoom

        } catch {
            logger.error("Failed to set focus: \(error.localizedDescription)")
        }
    }
}
