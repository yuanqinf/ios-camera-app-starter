//
//  CameraManager+Zoom.swift
//  CameraStarter
//
//  Zoom, the macro switch to the ultra wide camera, and the depth check
//  that gates Portrait mode.
//

@preconcurrency import AVFoundation
import os.log
import UIKit

extension CameraManager {

    // MARK: - Zoom Control

    /// Set zoom factor
    /// - Parameter factor: Target zoom factor
    func setZoom(_ factor: CGFloat) {
        // If in macro mode and user manually changes zoom, exit macro mode first then set zoom
        if isMacroModeActive {

            sessionQueue.async { [weak self] in
                guard let self = self else { return }

                // 🔑 Check device availability before changing state
                guard let tripleCamera = self.getCaptureDevice(for: .back) else {
                    self.logger.error("❌ Cannot exit macro mode - Triple Camera not available")
                    return
                }

                // ✅ Mark as non-macro after confirming device available
                Task { @MainActor in
                    self.macroManager.setActive(false)
                }

                do {
                    self.captureSession.beginConfiguration()

                    // Remove current input (ultra-wide)
                    if let currentInput = self.deviceInput {
                        self.captureSession.removeInput(currentInput)
                    }

                    // Add Triple Camera
                    let tripleCameraInput = try AVCaptureDeviceInput(device: tripleCamera)
                    if self.captureSession.canAddInput(tripleCameraInput) {
                        self.captureSession.addInput(tripleCameraInput)
                        self.deviceInput = tripleCameraInput

                        // Set target zoom factor
                        try tripleCamera.lockForConfiguration()
                        defer { tripleCamera.unlockForConfiguration() }

                        let clampedZoom = min(max(factor, tripleCamera.minAvailableVideoZoomFactor), tripleCamera.maxAvailableVideoZoomFactor)
                        tripleCamera.videoZoomFactor = clampedZoom

                        if tripleCamera.isFocusModeSupported(.continuousAutoFocus) {
                            tripleCamera.focusMode = .continuousAutoFocus
                        }

                        // Update rotation coordinator
                        self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                            device: tripleCamera,
                            previewLayer: self.previewLayer
                        )

                        Task { @MainActor in
                            self.zoomManager?.updateCurrentZoom(clampedZoom)
                            self.startFocusObservation(for: tripleCamera)
                            self.startLensPositionObservation(for: tripleCamera)
                            self.logger.info("✅ Exited macro mode and set zoom to \(String(format: "%.1f", clampedZoom))x")
                        }
                    } else {
                        throw CameraError.sessionConfigurationFailed
                    }

                    self.captureSession.commitConfiguration()

                } catch {
                    self.captureSession.commitConfiguration()
                    self.logger.error("❌ Failed to exit macro mode: \(error.localizedDescription)")
                }
            }
            return
        }

        guard let device = deviceInput?.device else {
            logger.error("No device available for zoom")
            return
        }

        // Immediately update UI state
        self.currentZoomFactor = factor

        zoomManager?.setZoom(factor, on: device)
    }

    /// Set zoom factor with optional animation
    /// - Parameters:
    ///   - factor: Target zoom factor
    ///   - animated: Whether to animate the zoom transition (for snap-to-preset)
    func setZoom(_ factor: CGFloat, animated: Bool) {
        guard !isMacroModeActive else {
            // For animated zoom, we don't support macro mode exit
            setZoom(factor)
            return
        }

        guard let device = deviceInput?.device else {
            logger.error("No device available for zoom")
            return
        }

        // Immediately update UI state
        self.currentZoomFactor = factor

        zoomManager?.setZoom(factor, on: device, animated: animated)
    }


    /// Update zoom range and available presets (called during device initialization)
    func updateZoomCapabilities(for device: AVCaptureDevice) {
        let isFront = device.position == .front
        self.isFrontCamera = isFront

        // Sync currentZoomFactor to default value
        let defaultZoom: CGFloat = isFront ? config.zoom.defaultFrontCameraZoom : config.zoom.defaultBackCameraZoom
        self.currentZoomFactor = defaultZoom

        zoomManager?.updateCapabilities(for: device, isFront: isFront)
    }

    // MARK: - Portrait and Macro Mode Control

    /// Manually toggle macro mode (called when tapping macro icon)
    func toggleMacroMode() {
        let shouldActivate = macroManager.toggleManualMode()

        if shouldActivate {
            activateMacroMode()
        } else {
            deactivateMacroMode()
        }
    }

    /// Check if current lens supports depth data
    func checkDepthCapability() -> Bool {
        // Allow portrait mode in macro mode (uses computed depth)
        if isMacroModeActive {
            return true  // Allow portrait effects in macro mode
        }

        // Main camera (2x) and telephoto (6x) support hardware depth
        // Ultra-wide (1x) doesn't support
        let deviceZoom = currentZoomFactor
        return deviceZoom >= config.portrait.minZoomForHardwareDepth
            && deviceZoom <= config.portrait.maxZoomForHardwareDepth
    }
}

extension CameraManager {

    // MARK: - Macro Mode Observation

    /// Start observing lens position (for macro detection)
    func startLensPositionObservation(for device: AVCaptureDevice) {
        // Remove old observer
        lensPositionObservation?.invalidate()


        // Observe lensPosition property (0.0 = infinity, 1.0 = closest focus)
        lensPositionObservation = device.observe(\.lensPosition, options: [.new, .initial]) { [weak self] device, change in
            guard let self = self else { return }
            guard let lensPosition = change.newValue else { return }

            Task { @MainActor in
                self.handleLensPositionChange(lensPosition: lensPosition)
            }
        }

    }

    /// Stop lens position observation
    func stopLensPositionObservation() {
        lensPositionObservation?.invalidate()
        lensPositionObservation = nil
    }

    /// Handle lens position change (update current lensPosition)
    private func handleLensPositionChange(lensPosition: Float) {
        // Skip if camera is stopped
        guard isRunning else { return }

        // Store current lensPosition (for per-frame detection)
        currentLensPosition = lensPosition

        // Macro detection logic moved to checkMacroConditionPerFrame()
        // Indicator state also managed by macroManager
    }

    /// Per-frame macro condition check (called from video frame callback)
    func checkMacroConditionPerFrame(lensPosition: Float) {
        let action = macroManager.checkConditions(
            lensPosition: lensPosition,
            isAdjustingFocus: isAdjustingFocus,
            currentZoom: currentZoomFactor,
            isBackCamera: currentDevice == .back,
            hasUltraWide: ultraWideDevice != nil
        )

        switch action {
        case .activate:
            activateMacroMode()
        case .deactivate:
            deactivateMacroMode()
        case .none:
            break
        }
    }

    /// Activate macro mode (switch to ultra-wide + 2x crop)
    private func activateMacroMode() {
        guard !isMacroModeActive else { return }
        guard let ultraWide = ultraWideDevice else { return }

        macroSwitchingManager.activateMacroMode(
            ultraWideDevice: ultraWide,
            context: createMacroSwitchContext(),
            macroManager: macroManager,
            portraitManager: portraitManager,
            currentZoom: currentZoomFactor
        )
    }

    /// Exit macro mode (switch back to Triple Camera)
    private func deactivateMacroMode() {
        guard isMacroModeActive else { return }
        guard let tripleCamera = getCaptureDevice(for: .back) else {
            logger.error("Cannot get Triple Camera device for macro deactivation")
            return
        }

        macroSwitchingManager.deactivateMacroMode(
            tripleCameraDevice: tripleCamera,
            context: createMacroSwitchContext(),
            macroManager: macroManager
        )
    }

    /// Create macro switch context
    private func createMacroSwitchContext() -> MacroSwitchingManager.SwitchContext {
        MacroSwitchingManager.SwitchContext(
            captureSession: captureSession,
            currentInput: deviceInput,
            videoOutput: videoOutput,
            sessionQueue: sessionQueue,
            videoOutputQueue: videoOutputQueue,
            previewLayer: previewLayer,
            updateDeviceInput: { [weak self] input in
                self?.deviceInput = input
            },
            videoDelegate: self,
            updateRotationCoordinator: { [weak self] device in
                guard let self = self else { return }
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: self.previewLayer
                )
            },
            restartObservers: { [weak self] device in
                self?.startFocusObservation(for: device)
                self?.startLensPositionObservation(for: device)
            },
            updateZoom: { [weak self] zoom in
                self?.zoomManager?.updateCurrentZoom(zoom)
            }
        )
    }
}
