//
//  CameraManager+Photo.swift
//  CameraStarter
//
//  Taking photos: flash, capture settings, and the delegate callbacks that
//  hand finished photos to the photo streams.
//

@preconcurrency import AVFoundation
import os.log
import UIKit

extension CameraManager {

    // MARK: - Capture Lifecycle Management

    @MainActor
    private func beginCaptureLifecycle() {
        pendingStopAfterCapture = false
        isCapturingPhoto = true

        if captureBackgroundTask == .invalid {
            captureBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PhotoCapture") { [weak self] in
                self?.logger.warning("Background task expired during capture")
                self?.endCaptureBackgroundTask()
            }
        }
    }

    @MainActor
    private func finishCaptureLifecycle() {
        isCapturingPhoto = false
        endCaptureBackgroundTask()

        if pendingStopAfterCapture {
            pendingStopAfterCapture = false
            stop(immediately: true)
        }
    }

    @MainActor
    private func endCaptureBackgroundTask() {
        guard captureBackgroundTask != .invalid else { return }

        // Save task ID first and immediately set to invalid to prevent race condition
        let taskToEnd = captureBackgroundTask
        captureBackgroundTask = .invalid

        // Then end the task
        UIApplication.shared.endBackgroundTask(taskToEnd)
    }
}

extension CameraManager {

    // MARK: - Flash Control

    /// Toggle flash mode (auto -> off -> on -> auto)
    func toggleFlashMode() {
        switch flashMode {
        case .auto:
            flashMode = .off
        case .off:
            flashMode = .on
        case .on:
            flashMode = .auto
        }
    }

    // MARK: - Photo Capture

    /// Take photo
    func takePhoto() {
        // Only allow photo capture in photo mode
        guard cameraMode == .photo else {
            logger.warning("takePhoto called in video mode, ignoring (cameraMode=\(self.cameraMode.rawValue))")
            return
        }

        // Check if camera is running
        guard isRunning else {
            logger.error("Camera is not running")
            return
        }

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // Read all needed state on main thread (avoid cross-thread access later)
        let isPortraitMode = (captureMode == .portrait)
        let isMacro = self.isMacroModeActive

        // Record capture start (begin background task to avoid early suspension)
        Task { @MainActor in
            self.beginCaptureLifecycle()
        }

        // Zero shutter lag: iOS Responsive Capture uses buffered frames
        // Capture immediately - NO focus/exposure locking needed
        // iOS handles this automatically with ZSL buffer when isResponsiveCaptureEnabled = true
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            guard let photoOutput = self.photoOutput else {
                self.logger.error("Photo output not available")
                Task { @MainActor in
                    self.finishCaptureLifecycle()
                }
                return
            }

            // HEIC where the device can encode it, the system default otherwise
            let photoSettings = photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()

            // Set max resolution (match native camera)
            photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions

            // Use .quality for best computational photography results (Deep Fusion, Smart HDR)
            photoSettings.photoQualityPrioritization = .quality

            // Auto-enable computational photography features
            photoSettings.isAutoRedEyeReductionEnabled = true

            // Note: Content-Aware Distortion Correction is pre-enabled at camera startup
            // to avoid ~300ms first-capture delay. No need to set it here.

            // Configure flash mode
            if self.isFrontCamera {
                photoSettings.flashMode = .off
            } else if self.flashManager.isFlashModeSupported(self.flashMode, on: photoOutput) {
                photoSettings.flashMode = self.flashMode.systemFlashMode
            } else {
                photoSettings.flashMode = .off
            }

            // Configure depth data capture (Portrait mode)
            if isPortraitMode {
                if isMacro {
                    photoSettings.isDepthDataDeliveryEnabled = false
                } else if photoOutput.isDepthDataDeliveryEnabled {
                    photoSettings.isDepthDataDeliveryEnabled = true
                    photoSettings.embedsDepthDataInPhoto = true
                    if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                        photoSettings.isPortraitEffectsMatteDeliveryEnabled = true
                        photoSettings.embedsPortraitEffectsMatteInPhoto = true
                    }
                    let availableMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
                    if !availableMatteTypes.isEmpty {
                        photoSettings.enabledSemanticSegmentationMatteTypes = availableMatteTypes
                    }
                } else {
                    photoSettings.isDepthDataDeliveryEnabled = false
                }
            } else {
                photoSettings.isDepthDataDeliveryEnabled = false
            }

            // Configure Live Photo capture
            if self.isLivePhotoEnabled && photoOutput.isLivePhotoCaptureEnabled {
                let movieURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                photoSettings.livePhotoMovieFileURL = movieURL

                // Register capture in LivePhotoManager BEFORE triggering capturePhoto
                // to avoid race condition where delegate callbacks arrive before registration
                let photoID = photoSettings.uniqueID
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    let started = await self.livePhotoManager.startCapture(id: photoID, movieURL: movieURL)
                    if !started {
                        self.logger.warning("Failed to start Live Photo capture - limit reached")
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            }

            // Apply rotation
            if let rotationCoordinator = self.rotationCoordinator,
               let photoOutputConnection = photoOutput.connection(with: .video) {
                let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
                photoOutputConnection.videoRotationAngle = rotationAngle
            }

            photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {


    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            logger.error("Error capturing photo: \(error.localizedDescription)")
            // Cancel Live Photo capture on error
            Task {
                await livePhotoManager.cancelCapture(id: photo.resolvedSettings.uniqueID)
            }
            Task { @MainActor [weak self] in
                self?.finishCaptureLifecycle()
            }
            return
        }

        let photoID = photo.resolvedSettings.uniqueID
        let isLivePhoto = photo.resolvedSettings.livePhotoMovieDimensions.width > 0

        if isLivePhoto {
            // Live Photo: Register photo part, wait for movie to complete
            Task {
                await livePhotoManager.completePhotoCapture(id: photoID, photo: photo)
                logger.info("Live Photo: Photo part completed, waiting for movie...")
            }
        }

        // Send photo to stream (for both regular and Live Photo)
        // Use background task to ensure location fetch + photo delivery completes even if app exits
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Background task to protect location fetch (may take up to 3s if no cached location)
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "PhotoLocationFetch") {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }

            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }

            // Request location (returns cached immediately if available, else waits up to 3s)
            let location = await self.locationManager.requestInstantLocation()

            // Send photo to stream
            self.photoContinuation.yield((photo, location))

            // Photo capture complete
            Task { @MainActor in
                self.finishCaptureLifecycle()
            }
        }
    }

    /// Live Photo movie file processing complete callback
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error = error {
            logger.error("Live Photo movie processing error: \(error.localizedDescription)")
            Task {
                await livePhotoManager.cancelCapture(id: resolvedSettings.uniqueID)
            }
            return
        }

        let photoID = resolvedSettings.uniqueID
        logger.info("Live Photo: Movie processing completed for \(photoID)")

        Task {
            await livePhotoManager.completeMovieProcessing(id: photoID)
        }
    }

    /// Deferred photo processing callback (Deferred Photo Processing)
    /// When isAutoDeferredPhotoDeliveryEnabled = true, system may return proxy object instead of final photo
    /// Background will continue processing Deep Fusion / Photonic Engine computational photography, auto-update Photos Library when complete
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
        error: Error?
    ) {
        if let error = error {
            logger.error("Deferred photo proxy error: \(error.localizedDescription)")
            Task { @MainActor [weak self] in
                self?.finishCaptureLifecycle()
            }
            return
        }

        guard let proxy = deferredPhotoProxy else {
            logger.warning("Deferred photo proxy is nil")
            return
        }

        // Get location info and save proxy photo
        // Use background task to ensure location fetch + photo delivery completes even if app exits
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Background task to protect location fetch
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "DeferredPhotoLocationFetch") {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }

            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }

            let location = await self.locationManager.requestInstantLocation()

            // Send proxy photo to stream (system will complete processing in background and auto-update)
            self.deferredPhotoContinuation.yield((proxy, location))

            // Restore focus and exposure
            Task { @MainActor in
                self.finishCaptureLifecycle()
            }
        }
    }
}
