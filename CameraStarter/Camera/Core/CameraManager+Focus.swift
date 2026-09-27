//
//  CameraManager+Focus.swift
//  CameraStarter
//
//  Tap to focus, tap to lock a subject, focus observation, and the preview
//  frames that feed subject detection.
//

@preconcurrency import AVFoundation
import os.log
import UIKit

extension CameraManager {

    // MARK: - Focus Control

    /// Focus at specified point
    /// - Parameter point: Screen coordinate point (needs conversion to device coordinates)
    func focus(at point: CGPoint) {
        guard let device = deviceInput?.device else {
            logger.error("No device available for focus")
            return
        }

        // Convert screen coordinates to device coordinates (0-1 range)
        guard let devicePoint = CoordinateConverter.uiToDevice(point: point, previewLayer: previewLayer) else {
            logger.error("Failed to convert UI point to device coordinates")
            return
        }

        // Record manual focus time to prevent immediate reset by subjectAreaDidChange
        lastManualFocusTime = Date()

        sessionQueue.async { [weak self] in
            self?.focusControl.focus(at: devicePoint, on: device)
        }
    }

    /// Handle tap with subject selection logic
    /// - Parameters:
    ///   - point: Screen coordinate point
    ///   - currentDetections: Current subject detections from SubjectDetector
    ///   - previewBounds: The bounds of the preview area
    /// - Returns: The subject that was selected (if any), or nil if tap was on empty area
    func handleTapWithSubjectSelection(
        at point: CGPoint,
        currentDetections: [SubjectDetectionResult],
        previewBounds: CGRect
    ) -> SubjectDetectionResult? {
        // Convert tap point to normalized coordinates (0-1)
        let normalizedPoint = CGPoint(
            x: point.x / previewBounds.width,
            y: point.y / previewBounds.height
        )

        // Check if tap is inside any subject's bounding box
        for subject in currentDetections {
            // Subject bounding box is in Vision coordinates (origin at bottom-left)
            // Need to flip Y for UI coordinates (origin at top-left)
            let uiBox = CGRect(
                x: subject.boundingBox.origin.x,
                y: 1 - subject.boundingBox.origin.y - subject.boundingBox.height,
                width: subject.boundingBox.width,
                height: subject.boundingBox.height
            )

            if uiBox.contains(normalizedPoint) {
                // Tap is on this subject - lock onto it
                subjectLockService.lockOn(subject: subject)
                logger.info("Manual lock on subject at tap location")
                return subject
            }
        }

        // Tap is on empty area - keep manual focus mode, just focus at that point
        // User can double-tap or use other gesture to return to auto mode
        // Don't unlock - this allows manual focus to work without resetting to auto
        logger.info("Tap on empty area - manual focus (keeping current tracking mode)")
        return nil
    }
}

extension CameraManager {

    // MARK: - Focus Observation

    /// Start observing focus state changes
    func startFocusObservation(for device: AVCaptureDevice) {
        // Remove old observer
        focusObservation?.invalidate()

        // Observe adjustingFocus property (for detecting focus state)
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] device, change in
            guard let self = self else { return }

            let isAdjusting = change.newValue ?? false

            Task { @MainActor in
                self.isAdjustingFocus = isAdjusting
            }
        }
    }

    /// Stop observing focus state
    func stopFocusObservation() {
        focusObservation?.invalidate()
        focusObservation = nil
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    // Note: This is called on videoOutputQueue, NOT on main thread
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Extract pixel buffer before crossing actor boundary (CMSampleBuffer is not Sendable)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // All processing happens on main thread
        Task { @MainActor [weak self, pixelBuffer] in
            guard let self = self else { return }

            // Skip processing if camera is stopped
            guard self.isRunning else { return }

            // Pass pixel buffer to subject detector (processes asynchronously internally)
            self.subjectDetector.detectSubjects(in: pixelBuffer, isFrontCamera: self.isFrontCamera)
        }
    }
}
