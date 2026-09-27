//
//  CameraManager+Session.swift
//  CameraStarter
//
//  Starting, stopping and configuring the capture session, switching
//  cameras, and recovering from interruptions.
//

@preconcurrency import AVFoundation
import os.log
import UIKit

extension CameraManager {

    // MARK: - Session Monitoring

    /// Set up Session interruption and error monitoring
    func setupSessionObservers() {
        // Prevent duplicate observer registration
        guard !sessionObserversSetup else { return }

        // Monitor session interruptions (calls, FaceTime, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: captureSession
        )

        // Monitor session interruption end
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: captureSession
        )

        // Monitor session runtime errors
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: captureSession
        )

        // Monitor subject area changes (subject moved, trigger refocus)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subjectAreaDidChange),
            name: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil  // Listen to all devices
        )

        sessionObserversSetup = true
    }

    @objc private func sessionWasInterrupted(notification: NSNotification) {
        guard let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reasonIntegerValue = AVCaptureSession.InterruptionReason(rawValue: userInfoValue) else {
            logger.warning("⚠️ Session was interrupted (unknown reason)")
            return
        }

        logger.warning("⚠️ Session was interrupted: reason=\(userInfoValue)")

        Task { @MainActor in
            switch reasonIntegerValue {
            case .videoDeviceNotAvailableInBackground:
                self.logger.info("Camera unavailable in background")
            case .audioDeviceInUseByAnotherClient:
                self.logger.info("Audio device in use by another app")
            case .videoDeviceInUseByAnotherClient:
                self.logger.warning("⚠️ Camera in use by another app - session stopped")
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                self.logger.warning("⚠️ Camera unavailable with multiple apps")
            case .videoDeviceNotAvailableDueToSystemPressure:
                self.logger.error("❌ Camera unavailable due to system pressure")
            default:
                self.logger.warning("⚠️ Session interrupted: unknown reason")
            }
        }
    }

    @objc private func sessionInterruptionEnded(notification: NSNotification) {
        logger.info("✅ Session interruption ended - camera available again")

        // After interruption ends, session should auto-recover
        // But we need to verify video output connection is still valid
        Task { @MainActor in
            // Wait briefly for session to stabilize
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Verify session is actually running
            if !self.captureSession.isRunning {
                logger.warning("⚠️ Session not running after interruption - attempting restart")
                try? await self.start()
            }

            // 🔧 Ensure depth data settings weren't reset by system
            self.ensureDepthDataEnabled()
        }
    }

    @objc private func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            logger.error("❌ Session runtime error (unknown)")
            return
        }

        logger.error("❌ Session runtime error: \(error.localizedDescription)")

        // Decide whether to attempt recovery based on error type
        Task { @MainActor in
            if error.code == .mediaServicesWereReset {
                logger.info("🔄 Media services reset - attempting to restart session")

                // Media services reset, need to reconfigure session
                self.isSessionConfigured = false

                do {
                    try await self.start()
                    logger.info("✅ Session restarted successfully after media services reset")
                } catch {
                    logger.error("❌ Failed to restart session: \(error.localizedDescription)")
                }
            } else if error.code == .deviceAlreadyUsedByAnotherSession {
                logger.error("❌ Device already in use by another session")
            } else {
                logger.error("❌ Unhandled session error: \(error.code.rawValue)")
            }
        }
    }

    @objc private func subjectAreaDidChange(notification: NSNotification) {
        // Check if we're in manual focus cooldown period
        // This prevents the system from immediately resetting manual focus
        if let lastFocus = lastManualFocusTime {
            let elapsed = Date().timeIntervalSince(lastFocus)
            if elapsed < manualFocusCooldown {
                // Still in cooldown - don't reset focus
                return
            }
        }

        // Subject moved significantly - trigger refocus for responsive subject tracking
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.deviceInput?.device,
                  device.isFocusModeSupported(.continuousAutoFocus) else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                // Reset to continuous autofocus (will refocus on new subject position)
                device.focusMode = .continuousAutoFocus

                // Also reset exposure to continuous auto for proper metering on moved subject
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

            } catch {
                self.logger.error("Failed to refocus after subject change: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lifecycle

    /// Force reset camera session to clean state
    /// Call this when camera is in an inconsistent state that prevents normal operation
    private func forceResetSession() {
        logger.warning("🔄 Force resetting camera session...")

        // 🔧 Preserve current camera mode - will be restored after reset
        let previousMode = cameraMode

        // Clear all internal state flags first
        isRunning = false
        isSessionConfigured = false
        pendingStopAfterCapture = false

        // Reset mode states (but preserve cameraMode for later restoration)
        cameraMode = .photo  // Temporarily set to photo for clean restart
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        // Store previous mode for restoration after session restart
        // Will be used by start() to switch back if needed
        self.pendingModeRestore = previousMode != .photo ? previousMode : nil

        // 🔧 All session operations MUST be on sessionQueue to avoid race conditions
        // Using DispatchQueue.sync to block until complete, but checking if we're already on the queue
        let resetBlock = { [weak self] in
            guard let self = self else { return }

            // Stop session if running
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }

            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }

            // Remove all inputs
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }

            // Remove ALL outputs (including photo output - will be recreated)
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }
        }

        // Check if we're already on sessionQueue to avoid deadlock
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            resetBlock()
        } else {
            sessionQueue.sync(execute: resetBlock)
        }

        // Clear ALL references (will be recreated in configureSession)
        deviceInput = nil
        audioInput = nil
        movieOutput = nil
        photoOutput = nil
        videoOutput = nil

        logger.info("✅ Camera session force reset complete")
    }

    /// Start camera
    func start() async throws {
        // 🔧 Prevent concurrent start calls (e.g., from both onAppear and onChange)
        guard !isStarting else {
            logger.info("⏳ Camera start already in progress, skipping duplicate call")
            return
        }

        // 🔧 Verify actual session state, not just isRunning flag
        // This handles race condition when user quickly backgrounds then foregrounds app
        let actuallyRunning = captureSession.isRunning

        if isRunning && actuallyRunning {
            // 🔧 Clear pending stop flag if start is called while already running
            // This handles the race condition: user backgrounds app during capture,
            // then foregrounds before capture completes
            if pendingStopAfterCapture {
                pendingStopAfterCapture = false
                logger.info("✅ Cleared pending stop - camera will stay running")
            }
            return
        }

        // Mark as starting to prevent concurrent calls
        isStarting = true
        defer { isStarting = false }

        // 🔧 If isRunning flag is true but session is not actually running,
        // force reset to clean state and proceed with full restart
        if isRunning && !actuallyRunning {
            logger.warning("⚠️ isRunning=true but session stopped - forcing full reset")
            forceResetSession()
        }

        // 🔧 If session is still running but isRunning is false (race condition from stop()),
        // wait briefly for session to stop, then force reset if still running
        if !isRunning && actuallyRunning {
            logger.warning("⚠️ Session still running but isRunning=false - waiting for stop...")
            // Wait briefly for the async stop to complete
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            if captureSession.isRunning {
                logger.warning("⚠️ Session still running after wait - forcing reset")
                forceResetSession()
            }
        }

        // 🔧 If session is stuck in unknown state, force reset
        if !isRunning && isSessionConfigured && !captureSession.isRunning {
            // Session was configured but not running - might be in bad state
            logger.warning("⚠️ Session configured but not running - forcing reset")
            forceResetSession()
        }

        // 🔧 If in video mode but not running, force reset to photo mode
        // This handles the case when app was backgrounded in video mode
        if cameraMode == .video && !captureSession.isRunning {
            logger.warning("⚠️ In video mode but session not running - forcing reset to photo mode")
            forceResetSession()
        }

        // 🔧 If photo output is missing (e.g., removed for video mode), force reset
        // This ensures we always have a valid photo output after restart
        if isSessionConfigured && photoOutput == nil {
            logger.warning("⚠️ Photo output is nil - forcing reset")
            forceResetSession()
        }

        // Check permissions
        state = .checkingPermissions
        try await checkAuthorization()

        // Configure session
        if !isSessionConfigured {
            state = .configuring
            try await configureSession()
            isSessionConfigured = true
        }

        // Start session
        state = .ready
        await startSession()
        state = .running
        isRunning = true

        // 🔧 Ensure depth data settings are enabled (prevent reset after configuration)
        ensureDepthDataEnabled()

        // 🔧 Reset macro state (clear previous manual disable flags, etc.)
        await MainActor.run {
            macroManager.resetState()
        }

        // 🔧 Restart lens position observation (needs re-listening after app restart)
        if let device = sessionController.deviceInput?.device {
            await MainActor.run {
                startLensPositionObservation(for: device)
                startFocusObservation(for: device)
            }
        }

        // 🔧 Re-set videoOutput delegate (removed in stop(), needs restoration after restart)
        if let videoOutput = videoOutput {
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                if videoOutput.sampleBufferDelegate == nil {
                    Task { @MainActor in
                        videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                    }
                }
            }
        }

        // 📍 Ensure location updates are running for photo geotagging
        locationManager.resumeLocationUpdates()

        // Start macro condition timer (4x/sec instead of per-frame)
        macroCheckTimer?.invalidate()
        macroCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRunning else { return }
                self.checkMacroConditionPerFrame(lensPosition: self.currentLensPosition)
            }
        }

        // 🔧 Restore camera mode if there was a pending restore after force reset
        if let modeToRestore = pendingModeRestore {
            pendingModeRestore = nil
            logger.info("🔄 Restoring camera mode to \(modeToRestore.rawValue) after reset")
            setCameraMode(modeToRestore)
        }
    }
}

extension CameraManager {

    /// Stop camera
    func stop(immediately: Bool = false) {
        if !immediately && isCapturingPhoto {
            pendingStopAfterCapture = true
            logger.info("⏳ Stop requested during capture – will stop after capture finishes")
            return
        }

        guard isRunning else { return }

        // Stop macro check timer
        macroCheckTimer?.invalidate()
        macroCheckTimer = nil

        // Reset tracking state (stop expensive Vision trackers)
        subjectDetector.resetTracking()

        // Stop focus observation first
        stopFocusObservation()
        stopLensPositionObservation()

        // Update state immediately
        isRunning = false
        state = .ready

        // 🔧 Stop session on sessionQueue - use async to avoid blocking UI
        // The session will stop asynchronously, but state flags are already updated
        // start() will detect and handle any state inconsistency via forceResetSession()
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Remove videoOutput delegate to prevent retain cycles
            if let videoOutput = self.videoOutput {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
            }

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }
}

extension CameraManager {

    // MARK: - Camera Switching

    /// Switch between front and back cameras
    func switchCamera() {
        // Reset tracking state before switching (trackers are camera-specific)
        subjectDetector.resetTracking()

        cameraSwitchingManager.switchCamera(
            from: currentDevice,
            context: createCameraSwitchContext(),
            macroManager: macroManager,
            portraitManager: portraitManager
        )
    }

    /// Create camera switch context
    private func createCameraSwitchContext() -> CameraSwitchingManager.SwitchContext {
        CameraSwitchingManager.SwitchContext(
            captureSession: captureSession,
            currentInput: deviceInput,
            sessionQueue: sessionQueue,
            previewLayer: previewLayer,
            updateDeviceInput: { [weak self] input in
                self?.deviceInput = input
            },
            updateRotationCoordinator: { [weak self] device in
                guard let self = self else { return }
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: self.previewLayer
                )
            },
            restartFocusObservation: { [weak self] device in
                self?.startFocusObservation(for: device)
            },
            updateZoomCapabilities: { [weak self] device in
                self?.updateZoomCapabilities(for: device)
            },
            updateZoom: { [weak self] zoom in
                self?.zoomManager?.updateCurrentZoom(zoom)
            },
            updateCurrentDevice: { [weak self] device in
                self?.currentDevice = device
            },
            resetSceneDetection: { },
            getCaptureDevice: { [weak self] position in
                self?.getCaptureDevice(for: position)
            }
        )
    }
}

extension CameraManager {

    // MARK: - Private Methods

    /// Ensure depth data and related features are enabled (for Portrait mode)
    /// Called after session recovery or configuration change to prevent system reset
    private func ensureDepthDataEnabled() {
        guard let photoOutput = self.photoOutput else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Check and enable depth data capture (required for Portrait mode)
            if photoOutput.isDepthDataDeliverySupported && !photoOutput.isDepthDataDeliveryEnabled {
                photoOutput.isDepthDataDeliveryEnabled = true
                self.logger.info("✅ Re-enabled depth data delivery after session change")
            }

            // Check and enable Portrait Effects Matte
            if photoOutput.isPortraitEffectsMatteDeliverySupported && !photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
                self.logger.info("✅ Re-enabled Portrait Effects Matte after session change")
            }

            // Check and enable Semantic Segmentation Mattes
            let availableMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
            if !availableMatteTypes.isEmpty && photoOutput.enabledSemanticSegmentationMatteTypes.isEmpty {
                photoOutput.enabledSemanticSegmentationMatteTypes = availableMatteTypes
                let matteTypeNames = availableMatteTypes.map { $0.rawValue }.joined(separator: ", ")
                self.logger.info("✅ Re-enabled semantic segmentation mattes after session change: [\(matteTypeNames)]")
            }
        }
    }

    /// Enable depth data, portrait effects matte, and semantic segmentation on a photo output.
    /// Must be called on sessionQueue after output is added to session.
    func configurePhotoOutputCapabilities(_ output: AVCapturePhotoOutput) {
        if output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = true
        }
        if output.isPortraitEffectsMatteDeliverySupported {
            output.isPortraitEffectsMatteDeliveryEnabled = true
        }
        let availableMatteTypes = output.availableSemanticSegmentationMatteTypes
        if !availableMatteTypes.isEmpty {
            output.enabledSemanticSegmentationMatteTypes = availableMatteTypes
        }
    }

    /// Configure photo output for highest quality capture (dimensions, quality prioritization,
    /// responsive capture, live photo, deferred delivery, distortion correction).
    /// Must be called on sessionQueue with a valid device.
    func configurePhotoOutputQuality(_ output: AVCapturePhotoOutput, device: AVCaptureDevice) {
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        if let maxDimensions = supportedDimensions.last {
            output.maxPhotoDimensions = maxDimensions
        }
        output.maxPhotoQualityPrioritization = .quality
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = true
        }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = false
        }
        if output.isLivePhotoCaptureSupported {
            output.isLivePhotoCaptureEnabled = true
        }
        if output.isAutoDeferredPhotoDeliverySupported {
            output.isAutoDeferredPhotoDeliveryEnabled = true
        }
        if output.isContentAwareDistortionCorrectionSupported {
            output.isContentAwareDistortionCorrectionEnabled = true
        }
    }

    /// Set zoom factor to defaultZoom (clamped to device range), falling back to minZoom.
    /// Device must already be locked for configuration.
    func setDefaultZoom(on device: AVCaptureDevice, defaultZoom: CGFloat) {
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        if defaultZoom >= minZoom && defaultZoom <= maxZoom {
            device.videoZoomFactor = defaultZoom
        } else {
            device.videoZoomFactor = minZoom
        }
    }

    /// Throws unless the app may use the camera, asking the first time.
    ///
    /// `start()` calls this before configuring the session, so there is nothing
    /// on the session to hold back while the system prompt is up.
    private func checkAuthorization() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let granted = status == .notDetermined
            ? await AVCaptureDevice.requestAccess(for: .video)
            : status == .authorized
        guard granted else {
            logger.error("Camera access not granted (status \(status.rawValue))")
            throw CameraError.permissionDenied
        }
    }

    /// Configure camera session
    private func configureSession() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CameraError.unknown("Self is nil"))
                    return
                }

                do {
                    self.captureSession.beginConfiguration()
                    defer { self.captureSession.commitConfiguration() }

                    // 🔧 Safety check: ensure no existing inputs/outputs before configuring
                    // This handles edge cases where forceResetSession may not have fully completed
                    if !self.captureSession.inputs.isEmpty {
                        self.logger.warning("⚠️ Session has \(self.captureSession.inputs.count) existing inputs - removing...")
                        for input in self.captureSession.inputs {
                            self.captureSession.removeInput(input)
                        }
                    }
                    if !self.captureSession.outputs.isEmpty {
                        self.logger.warning("⚠️ Session has \(self.captureSession.outputs.count) existing outputs - removing...")
                        for output in self.captureSession.outputs {
                            self.captureSession.removeOutput(output)
                        }
                    }

                    // Configure session preset - photo quality
                    if self.captureSession.canSetSessionPreset(.photo) {
                        self.captureSession.sessionPreset = .photo
                    } else if self.captureSession.canSetSessionPreset(.high) {
                        self.captureSession.sessionPreset = .high
                    }

                    // Get device
                    guard let device = self.getCaptureDevice(for: .back) else {
                        throw CameraError.deviceNotAvailable
                    }

                    // Add input
                    let deviceInput = try AVCaptureDeviceInput(device: device)
                    guard self.captureSession.canAddInput(deviceInput) else {
                        self.logger.error("Cannot add device input - inputs: \(self.captureSession.inputs.count), outputs: \(self.captureSession.outputs.count)")
                        throw CameraError.sessionConfigurationFailed
                    }
                    self.captureSession.addInput(deviceInput)
                    self.deviceInput = deviceInput

                    // Add photo output
                    let photoOutput = AVCapturePhotoOutput()
                    guard self.captureSession.canAddOutput(photoOutput) else {
                        self.logger.error("Cannot add photo output")
                        throw CameraError.sessionConfigurationFailed
                    }
                    self.captureSession.addOutput(photoOutput)
                    self.photoOutput = photoOutput

                    self.configurePhotoOutputCapabilities(photoOutput)
                    self.configurePhotoOutputQuality(photoOutput, device: device)

                    // Add video data output (for subject detection)
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    // Set delegate synchronously on videoOutputQueue (safe during configuration)
                    videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)

                    guard self.captureSession.canAddOutput(videoOutput) else {
                        self.logger.error("Cannot add video output")
                        throw CameraError.sessionConfigurationFailed
                    }
                    self.captureSession.addOutput(videoOutput)
                    self.videoOutput = videoOutput

                    // Initialize rotation coordinator
                    self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                        device: device,
                        previewLayer: self.previewLayer
                    )

                    // Start focus state observation
                    Task { @MainActor in
                        self.startFocusObservation(for: device)
                        self.startLensPositionObservation(for: device)
                    }

                    // Get ultra-wide device (for macro mode)
                    if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
                        Task { @MainActor in
                            self.ultraWideDevice = ultraWide
                        }
                    }

                    // Update zoom capabilities and available presets
                    Task { @MainActor in
                        self.updateZoomCapabilities(for: device)
                    }

                    // Configure device parameters (zoom, focus, exposure)
                    do {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }

                        // 1. Set default zoom (main camera 48MP, displayed as "1" in UI)
                        // Triple Camera: system 1.0x=ultra-wide, 2.0x=main 48MP, 3.0x=telephoto
                        // UI mapping: .5 → 1.0x, 1 → 2.0x, 2 → 4.0x, 3 → 6.0x
                        let defaultZoom = config.zoom.defaultBackCameraZoom
                        let minZoom = device.minAvailableVideoZoomFactor
                        let maxZoom = device.maxAvailableVideoZoomFactor

                        if defaultZoom >= minZoom && defaultZoom <= maxZoom {
                            device.videoZoomFactor = defaultZoom
                            Task { @MainActor in
                                self.zoomManager?.updateCurrentZoom(defaultZoom)
                            }
                        } else if 1.0 >= minZoom && 1.0 <= maxZoom {
                            device.videoZoomFactor = 1.0
                            Task { @MainActor in
                                self.zoomManager?.updateCurrentZoom(1.0)
                            }
                        }

                        // 2. Configure exposure mode
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }

                        // 3. Configure white balance (continuous auto for accurate colors)
                        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                            device.whiteBalanceMode = .continuousAutoWhiteBalance
                        }

                        // 4. Enable automatic low light boost
                        if device.isLowLightBoostSupported {
                            device.automaticallyEnablesLowLightBoostWhenAvailable = true
                        }

                        // 5. Configure focus mode based on autofocus system type
                        // Phase detection: fast & subtle, use continuous AF freely
                        // Contrast detection: slower with visible "hunting", enable smooth AF
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }

                        // Enable smooth autofocus for contrast detection systems
                        // Reduces "focus hunting" which is more visible on older/front cameras
                        let afSystem = device.activeFormat.autoFocusSystem
                        if afSystem == .contrastDetection && device.isSmoothAutoFocusSupported {
                            device.isSmoothAutoFocusEnabled = true
                            self.logger.info("✅ Smooth AutoFocus enabled (contrast detection system)")
                        }

                        // 6. Enable subject area change monitoring (iOS 17+ responsive focus)
                        // When the subject moves significantly, system triggers notification for refocus
                        device.isSubjectAreaChangeMonitoringEnabled = true
                    } catch {
                        self.logger.error("❌ Failed to configure device: \(error.localizedDescription)")
                    }
                    continuation.resume()
                } catch {
                    self.logger.error("Session configuration failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Start session
    private func startSession() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                self.captureSession.startRunning()

                // Verify session start status
                if !self.captureSession.isRunning {
                    self.logger.error("❌ Session failed to start running!")
                }

                continuation.resume()
            }
        }

        // Pre-warm Content-Aware Distortion Correction asynchronously after session starts
        // This avoids ~300ms delay on first capture without blocking the UI
        sessionQueue.async { [weak self] in
            guard let self = self, let photoOutput = self.photoOutput else { return }
            if photoOutput.isContentAwareDistortionCorrectionSupported {
                photoOutput.isContentAwareDistortionCorrectionEnabled = true
                self.logger.info("✅ Content-Aware Distortion Correction pre-warmed")
            }
        }
    }

    /// Get camera device for specified position
    nonisolated func getCaptureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // iPhone 15 Pro: Prefer multi-camera system (Triple Camera)
        // This provides full 24MP main camera + multi-lens switching capability

        // 1. Preferred: Triple Camera (iPhone 15 Pro/Max, 14 Pro/Max, 13 Pro/Max)
        if let tripleCamera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position) {
            return tripleCamera
        }

        // 2. Secondary: Dual Wide Camera (iPhone 13/14 standard)
        if let dualWideCamera = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: position) {
            return dualWideCamera
        }

        // 3. Fallback: Dual Camera (older Plus models)
        if let dualCamera = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: position) {
            return dualCamera
        }

        // 4. Last resort: Single lens (basic models or front camera)
        if let wideAngleCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return wideAngleCamera
        }

        logger.error("❌ No suitable camera device found")
        return nil
    }
}
