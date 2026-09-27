//
//  CameraSwitchingManager.swift
//  CameraStarter
//
//  Handles front/back camera switching
//  Extracted from CameraManager to improve code organization
//

@preconcurrency import AVFoundation
import os.log

/// Manager for coordinating front/back camera switching
@MainActor
final class CameraSwitchingManager {

    // MARK: - Types

    /// Context needed for camera switching operations
    struct SwitchContext {
        let captureSession: AVCaptureSession
        let currentInput: AVCaptureDeviceInput?
        let sessionQueue: DispatchQueue
        let previewLayer: AVCaptureVideoPreviewLayer

        /// Callback to update device input after switch
        let updateDeviceInput: (AVCaptureDeviceInput?) -> Void

        /// Callback to update rotation coordinator
        let updateRotationCoordinator: (AVCaptureDevice) -> Void

        /// Callback to restart focus observation
        let restartFocusObservation: (AVCaptureDevice) -> Void

        /// Callback to update zoom capabilities
        let updateZoomCapabilities: (AVCaptureDevice) -> Void

        /// Callback to update zoom factor
        let updateZoom: (CGFloat) -> Void

        /// Callback to update current device state
        let updateCurrentDevice: (CameraDevice) -> Void

        /// Callback to reset scene detection state
        let resetSceneDetection: () -> Void

        /// Function to get capture device for position
        let getCaptureDevice: (AVCaptureDevice.Position) -> AVCaptureDevice?
    }

    // MARK: - Private Properties

    private let config = CameraConfiguration.shared
    private let logger = Logger(subsystem: Log.subsystem, category: "CameraSwitchingManager")

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Switches between front and back cameras
    /// - Parameters:
    ///   - currentDevice: Current camera device (front/back)
    ///   - context: Switch context with session references and callbacks
    ///   - macroManager: Macro mode manager to reset state
    ///   - portraitManager: Portrait mode manager to disable portrait
    func switchCamera(
        from currentDevice: CameraDevice,
        context: SwitchContext,
        macroManager: MacroModeService,
        portraitManager: PortraitModeService
    ) {
        // Reset macro mode state
        macroManager.resetState()

        // Reset portrait mode (front camera doesn't support depth data)
        portraitManager.disablePortraitMode()

        let newDevice: CameraDevice = currentDevice == .back ? .front : .back

        context.sessionQueue.async { [weak self, context] in
            guard let self = self else { return }

            let position: AVCaptureDevice.Position = newDevice == .back ? .back : .front
            guard let newCameraDevice = context.getCaptureDevice(position) else {
                self.logger.error("Failed to get capture device for position: \(position.rawValue)")
                return
            }

            do {
                context.captureSession.beginConfiguration()

                // Remove old input
                if let currentInput = context.currentInput {
                    context.captureSession.removeInput(currentInput)
                }

                // Add new input
                let newInput = try AVCaptureDeviceInput(device: newCameraDevice)
                if context.captureSession.canAddInput(newInput) {
                    context.captureSession.addInput(newInput)

                    Task { @MainActor in
                        context.updateDeviceInput(newInput)
                    }

                    // Update rotation coordinator
                    Task { @MainActor in
                        context.updateRotationCoordinator(newCameraDevice)
                    }

                    // Update focus observation
                    Task { @MainActor in
                        context.restartFocusObservation(newCameraDevice)
                    }

                    // Update zoom capabilities
                    Task { @MainActor in
                        context.updateZoomCapabilities(newCameraDevice)
                    }

                    // Configure new camera device
                    self.configureNewDevice(
                        newCameraDevice,
                        position: position,
                        context: context
                    )

                    // Reset scene detection state
                    Task { @MainActor in
                        context.resetSceneDetection()
                        context.updateCurrentDevice(newDevice)
                    }
                } else {
                    throw CameraError.sessionConfigurationFailed
                }

                context.captureSession.commitConfiguration()

            } catch {
                context.captureSession.commitConfiguration()
                self.logger.error("Failed to switch camera: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private Methods

    /// Configures the new camera device after switching
    private nonisolated func configureNewDevice(
        _ device: AVCaptureDevice,
        position: AVCaptureDevice.Position,
        context: SwitchContext
    ) {
        // Calculate target zoom before configuration
        let defaultZoom: CGFloat = (position == .back)
            ? config.zoom.defaultBackCameraZoom
            : config.zoom.defaultFrontCameraZoom
        let clampedZoom = DeviceConfigurationHelper.clampZoom(defaultZoom, for: device)

        // Use consolidated helper for device configuration
        DeviceConfigurationHelper.configureSafely(device) { dev in
            // 1. Set default zoom
            dev.videoZoomFactor = clampedZoom

            // 2. Configure focus mode - use continuousAutoFocus for tracking
            if dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusMode = .continuousAutoFocus
            }

            // 3. Configure exposure mode
            if dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposureMode = .continuousAutoExposure
            }

            // 4. Enable subject area change monitoring (iOS 17+ responsive focus)
            dev.isSubjectAreaChangeMonitoringEnabled = true
        }

        // Update zoom on main thread
        Task { @MainActor in
            context.updateZoom(clampedZoom)
        }
    }
}
