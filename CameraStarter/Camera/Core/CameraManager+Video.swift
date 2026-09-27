//
//  CameraManager+Video.swift
//  CameraStarter
//
//  Switching between photo and video, recording, and the torch.
//

@preconcurrency import AVFoundation
import os.log
import UIKit
import VideoToolbox

// MARK: - Video Recording

extension CameraManager {

    /// Switch between photo and video mode
    /// - Parameters:
    ///   - mode: The camera mode to switch to
    ///   - completion: Called on main thread when configuration is complete
    func setCameraMode(_ mode: CameraMode, completion: (() -> Void)? = nil) {
        guard mode != cameraMode else {
            completion?()
            return
        }

        // Stop any ongoing recording
        if isRecording {
            stopRecording()
        }

        cameraMode = mode

        sessionQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?() }
                return
            }

            // Use beginConfiguration/commitConfiguration without stopping session
            // This allows seamless transition without preview interruption
            self.captureSession.beginConfiguration()

            if mode == .video {
                self.configureForVideoMode()
            } else {
                self.configureForPhotoMode()
            }

            self.captureSession.commitConfiguration()

            // For video mode on front camera: wait for exposure to stabilize
            // This prevents dark first frames when user starts recording
            if mode == .video, let device = self.deviceInput?.device, device.position == .front {
                // Wait up to 300ms for exposure to stabilize after format change
                let startWait = Date()
                let maxWait: TimeInterval = 0.3
                while device.isAdjustingExposure && Date().timeIntervalSince(startWait) < maxWait {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }

            // Ensure zoom state is synced before calling completion
            // This must happen on main thread before completion callback
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }

                // Sync zoom state from device (format change may have reset it)
                if let device = self.deviceInput?.device {
                    let deviceZoom = device.videoZoomFactor
                    self.currentZoomFactor = deviceZoom
                    self.zoomManager?.updateCurrentZoom(deviceZoom)
                }

                completion?()
            }
        }
    }

    /// Configure session for video mode
    private func configureForVideoMode() {
        guard let device = deviceInput?.device else { return }

        // 🔧 CRITICAL FIX: Temporarily remove photo output when in video mode
        // Photo output with depth data enabled conflicts with video format settings
        // This fixes error -11872 "Cannot Record"
        if let output = photoOutput {
            captureSession.removeOutput(output)
            logger.info("📹 Removed photo output for video mode")
        }

        // 🔧 Also remove video data output (subject detection) during video recording
        // It may conflict with movie output when using custom formats
        if let output = videoOutput {
            captureSession.removeOutput(output)
            logger.info("📹 Removed video data output for video mode")
        }

        // 🔧 Configure video format FIRST (before adding outputs)
        // Setting activeFormat automatically sets session to AVCaptureSessionPresetInputPriority
        // This allows custom format without preset conflicts
        configureVideoFormat(for: device)

        // Add audio input
        if audioInput == nil {
            if let audioDevice = AVCaptureDevice.default(for: .audio) {
                do {
                    let input = try AVCaptureDeviceInput(device: audioDevice)
                    if captureSession.canAddInput(input) {
                        captureSession.addInput(input)
                        audioInput = input
                    }
                } catch {
                    logger.error("Failed to add audio input: \(error.localizedDescription)")
                }
            }
        }

        // Add movie output AFTER format is configured
        // 🔧 Always check if movieOutput is in the session, not just if it's nil
        // This handles the case where movieOutput was removed but reference wasn't cleared
        let needsMovieOutput = movieOutput == nil || !captureSession.outputs.contains(where: { $0 === movieOutput })

        if needsMovieOutput {
            // Remove stale reference if exists
            if let staleOutput = movieOutput {
                if captureSession.outputs.contains(staleOutput) {
                    captureSession.removeOutput(staleOutput)
                }
                movieOutput = nil
            }

            let output = AVCaptureMovieFileOutput()
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                movieOutput = output
                logger.info("📹 Added movie output for video recording")
            } else {
                logger.error("❌ Cannot add movie output to session")
            }
        } else {
            logger.info("📹 Movie output already configured")
        }

        // Configure video settings on the movie output connection
        if let output = movieOutput, let connection = output.connection(with: .video) {
            // Apply stabilization mode
            // Front camera: no stabilization (matches native Camera, avoids FOV crop mismatch)
            // Back camera: apply user-selected stabilization mode
            let isFront = device.position == .front
            if connection.isVideoStabilizationSupported {
                if isFront {
                    // Front camera: disable stabilization to match preview FOV
                    connection.preferredVideoStabilizationMode = .off
                    logger.info("📹 Front camera: stabilization disabled")
                } else {
                    switch self.videoStabilizationMode {
                    case .standard:
                        connection.preferredVideoStabilizationMode = .standard
                    case .action:
                        connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                    }
                    logger.info("📹 Stabilization mode set: \(self.videoStabilizationMode.rawValue)")
                }
            }

            // Configure HEVC encoding with HDR support (native Camera uses HEVC + HDR)
            // Bitrate: ~50 Mbps for 4K, ~20 Mbps for 1080p (similar to native Camera)
            // HDR requires higher bitrate to preserve color depth
            let bitrate = isFront ? 20_000_000 : 60_000_000  // 1080p vs 4K HDR

            if output.availableVideoCodecTypes.contains(.hevc) {
                // Use Main10 profile for HDR/10-bit support (preserves HDR metadata)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 30  // Keyframe every 1 second at 30fps
                    ]
                ]
                output.setOutputSettings(videoSettings, for: connection)
                logger.info("📹 HEVC Main10 (HDR) encoding configured @ \(bitrate / 1_000_000) Mbps")
            } else if output.availableVideoCodecTypes.contains(.h264) {
                // Fallback to H.264
                let h264Bitrate = isFront ? 25_000_000 : 60_000_000
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: h264Bitrate,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 30
                    ]
                ]
                output.setOutputSettings(videoSettings, for: connection)
                logger.info("📹 H.264 encoding configured @ \(h264Bitrate / 1_000_000) Mbps")
            }

            logger.info("📹 Video connection configured: active=\(connection.isActive)")
        } else {
            logger.error("❌ No video connection available for movie output")
        }

        // Reset zoom after format change
        // Video format has different FOV, need to ensure zoom is at baseline
        // Front camera in video mode: always 1.0x (no zoom adjustment allowed)
        // Back camera in video mode: default 2.0x (UI 1x)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let isFront = device.position == .front
            setDefaultZoom(on: device, defaultZoom: isFront ? 1.0 : 2.0)
        } catch {
            logger.error("Failed to reset video zoom: \(error.localizedDescription)")
        }
    }

    /// Four-char codec string from a format description's media sub-type
    private func codecString(for format: AVCaptureDevice.Format) -> String {
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return String(format: "%c%c%c%c",
                      (type >> 24) & 0xFF, (type >> 16) & 0xFF,
                      (type >> 8) & 0xFF, type & 0xFF)
    }

    /// Search `device.formats` for the best standard-codec format at the given resolution
    private func findBestVideoFormat(
        for device: AVCaptureDevice,
        targetWidth: Int32,
        targetHeight: Int32,
        preferredFrameRate: Float64 = 30
    ) -> (format: AVCaptureDevice.Format, frameRate: Float64)? {
        let allowedCodecs = ["420v", "420f", "BGRA", "x420"]
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRate: Float64 = 0

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == targetWidth && dimensions.height == targetHeight else { continue }

            let codec = codecString(for: format)
            guard !codec.hasPrefix("ap"),
                  allowedCodecs.contains(where: { codec.hasPrefix($0) }) else { continue }

            let isHDR = codec.hasPrefix("x420")

            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= preferredFrameRate {
                    let currentIsHDR = bestFormat.map { codecString(for: $0).hasPrefix("x420") } ?? false
                    if bestFormat == nil || bestFrameRate != preferredFrameRate || (isHDR && !currentIsHDR) {
                        bestFormat = format
                        bestFrameRate = preferredFrameRate
                    }
                } else if bestFormat == nil && range.maxFrameRate >= 24 {
                    bestFormat = format
                    bestFrameRate = range.maxFrameRate
                }
            }
        }

        guard let format = bestFormat else { return nil }
        return (format, bestFrameRate)
    }

    /// Configure video format for the device (matching native Camera app: 4K 30fps back, 1080p 30fps front)
    private func configureVideoFormat(for device: AVCaptureDevice) {
        let isFrontCamera = device.position == .front
        let targetWidth: Int32 = isFrontCamera ? 1920 : 3840
        let targetHeight: Int32 = isFrontCamera ? 1080 : 2160

        var result = findBestVideoFormat(for: device, targetWidth: targetWidth, targetHeight: targetHeight)

        // Fallback to 1080p if 4K not available on back camera
        if result == nil && !isFrontCamera {
            logger.info("📹 4K not available, falling back to 1080p")
            result = findBestVideoFormat(for: device, targetWidth: 1920, targetHeight: 1080)
        }

        guard let (format, bestFrameRate) = result else {
            logger.warning("No suitable video format found for \(isFrontCamera ? "front" : "back") camera")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let codec = codecString(for: format)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(bestFrameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }

            let isHDR = codec.hasPrefix("x420")
            logger.info("📹 Video format configured: \(isFrontCamera ? "front" : "back") camera @ \(Int(dimensions.width))x\(Int(dimensions.height)) \(Int(bestFrameRate))fps, codec: \(codec)\(isHDR ? " (HDR)" : "")")
        } catch {
            logger.error("Failed to configure video format: \(error.localizedDescription)")
        }
    }

    /// Configure session for photo mode
    private func configureForPhotoMode() {
        // Remove movie output
        if let output = movieOutput {
            captureSession.removeOutput(output)
            movieOutput = nil
        }

        // Remove audio input
        if let input = audioInput {
            captureSession.removeInput(input)
            audioInput = nil
        }

        // Restore photo session preset
        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        }

        // 🔧 Re-add video data output if it was removed for video mode (for subject detection)
        if let output = videoOutput, !captureSession.outputs.contains(output) {
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                // Restore delegate
                output.setSampleBufferDelegate(self, queue: videoOutputQueue)
                logger.info("📷 Re-added video data output for photo mode")
            }
        }

        // 🔧 Re-add photo output if it was removed for video mode
        if let output = photoOutput, !captureSession.outputs.contains(output) {
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                logger.info("📷 Re-added photo output for photo mode")

                // Re-configure photo output settings (depth, mattes, quality)
                if let device = deviceInput?.device {
                    configurePhotoOutputCapabilities(output)
                    configurePhotoOutputQuality(output, device: device)
                }
            } else {
                logger.error("❌ Cannot re-add photo output to session")
            }
        }

        // Reset zoom to default after switching back to photo mode
        // Front camera: 1.0x, Back camera: 2.0x (UI 1x)
        if let device = deviceInput?.device {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let isFront = device.position == .front
                setDefaultZoom(on: device, defaultZoom: isFront ? 1.0 : 2.0)
            } catch {
                logger.error("Failed to restore photo format: \(error.localizedDescription)")
            }
        }
    }

    /// Start video recording
    func startRecording() {
        // 🔧 Detailed logging to diagnose why recording might not start
        guard cameraMode == .video else {
            logger.warning("⚠️ startRecording called but cameraMode=\(self.cameraMode.rawValue), not video")
            return
        }
        guard !isRecording else {
            logger.warning("⚠️ startRecording called but already recording")
            return
        }
        guard let output = movieOutput else {
            logger.error("❌ startRecording failed: movieOutput is nil")
            // Try to recover by reconfiguring video mode
            if deviceInput?.device != nil {
                logger.info("🔄 Attempting to reconfigure video mode...")
                sessionQueue.async { [weak self] in
                    self?.configureForVideoMode()
                }
            }
            return
        }

        // Verify video connection is available and active
        guard let connection = output.connection(with: .video) else {
            logger.error("❌ Cannot start recording: no video connection")
            return
        }
        guard connection.isActive else {
            logger.error("❌ Cannot start recording: video connection not active")
            return
        }

        // Create output URL
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        // Apply video orientation
        if let rotationCoordinator = rotationCoordinator {
            connection.videoRotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
        }

        // Apply stabilization mode (already set in configureForVideoMode, but ensure it's applied)
        // Front camera: no stabilization (matches native Camera, avoids FOV crop)
        let isFrontCamera = deviceInput?.device.position == .front
        if connection.isVideoStabilizationSupported {
            if isFrontCamera {
                connection.preferredVideoStabilizationMode = .off
            } else {
                switch videoStabilizationMode {
                case .standard:
                    connection.preferredVideoStabilizationMode = .standard
                case .action:
                    connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                }
            }
        }

        // Update state first (show recording UI immediately for responsiveness)
        isRecording = true
        recordingStartTime = Date()
        recordingDuration = 0
        let startDelay: TimeInterval = isFrontCamera ? 0.15 : 0  // 150ms delay for front camera

        if startDelay > 0 {
            sessionQueue.asyncAfter(deadline: .now() + startDelay) { [weak self] in
                guard let self = self, self.isRecording else { return }
                output.startRecording(to: outputURL, recordingDelegate: self)
                self.logger.info("📹 Front camera recording started after \(startDelay)s delay")
            }
        } else {
            // Start recording immediately for back camera
            output.startRecording(to: outputURL, recordingDelegate: self)
        }

        // Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            Task { @MainActor in
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }

        Haptics.medium()
    }

    /// Stop video recording
    func stopRecording() {
        guard isRecording else { return }

        movieOutput?.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
        Haptics.medium()
    }

    /// Toggle torch for video mode
    func toggleTorch() {
        guard cameraMode == .video else { return }
        guard let device = deviceInput?.device else { return }
        guard device.hasTorch else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.torchMode == .off {
                    try device.setTorchModeOn(level: 1.0)
                    Task { @MainActor in
                        self.isTorchEnabled = true
                    }
                } else {
                    device.torchMode = .off
                    Task { @MainActor in
                        self.isTorchEnabled = false
                    }
                }
            } catch {
                self.logger.error("Failed to toggle torch: \(error.localizedDescription)")
            }
        }
    }

    /// Set torch state explicitly
    func setTorch(enabled: Bool) {
        guard cameraMode == .video else { return }
        guard let device = deviceInput?.device else { return }
        guard device.hasTorch else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if enabled {
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }

                Task { @MainActor in
                    self.isTorchEnabled = enabled
                }
            } catch {
                self.logger.error("Failed to set torch: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.recordingDuration = 0
            self.recordingStartTime = nil

            // Turn off torch when recording ends
            if self.isTorchEnabled {
                self.setTorch(enabled: false)
            }

            if let error = error {
                self.logger.error("Recording failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            // Hand the file to whoever saves recordings
            let location = self.locationManager.currentLocation
            self.videoContinuation.yield((outputFileURL, location))
        }
    }
}
