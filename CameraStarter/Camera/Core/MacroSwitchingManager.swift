//
//  MacroSwitchingManager.swift
//  CameraStarter
//
//  Handles camera switching for macro mode (Ultra Wide ↔ Triple Camera)
//  Extracted from CameraManager to improve code organization
//

@preconcurrency import AVFoundation
import os.log
import UIKit

    /// Manager for coordinating macro mode camera switching
    /// Manages the actual AVCaptureSession reconfiguration when entering/exiting macro mode
    @MainActor
    final class MacroSwitchingManager {

        // MARK: - Types

        /// Context needed for macro switching operations
        nonisolated struct SwitchContext: @unchecked Sendable {
            let captureSession: AVCaptureSession
            let currentInput: AVCaptureDeviceInput?
            let videoOutput: AVCaptureVideoDataOutput?
            let sessionQueue: DispatchQueue
            let videoOutputQueue: DispatchQueue
            let previewLayer: AVCaptureVideoPreviewLayer

            /// Callback to update device input after switch
            let updateDeviceInput: (AVCaptureDeviceInput?) -> Void

            /// Callback for video output delegate
            let videoDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

            /// Callback to update rotation coordinator
            let updateRotationCoordinator: (AVCaptureDevice) -> Void

            /// Callback to restart observers after camera switch
            let restartObservers: (AVCaptureDevice) -> Void

            /// Callback to update zoom factor
            let updateZoom: (CGFloat) -> Void
        }

        private struct PreviewLayerBox: @unchecked Sendable {
            let layer: AVCaptureVideoPreviewLayer
        }

    // MARK: - Private Properties

    private let config = CameraConfiguration.shared
    private let logger = Logger(subsystem: Log.subsystem, category: "MacroSwitchingManager")

    // MARK: - Initialization

    init() {}

    // MARK: - Public Methods

    /// Activates macro mode by switching to Ultra Wide camera with 2x crop
    /// - Parameters:
    ///   - ultraWideDevice: The Ultra Wide camera device
    ///   - context: Switch context with session references and callbacks
    ///   - macroManager: The macro mode manager to update state
    ///   - portraitManager: The portrait mode manager to disable portrait
    ///   - currentZoom: Current zoom factor (to save for restoration)
    func activateMacroMode(
        ultraWideDevice: AVCaptureDevice,
        context: SwitchContext,
        macroManager: MacroModeService,
        portraitManager: PortraitModeService,
        currentZoom: CGFloat
    ) {
        guard !macroManager.isMacroModeActive else { return }


        // Smooth transition with snapshot overlay
        smoothCameraTransition(previewLayer: context.previewLayer) {
            context.sessionQueue.async { [weak self, context] in
                guard let self = self else { return }

                do {
                    context.captureSession.beginConfiguration()

                    // 1. Remove current input
                    if let currentInput = context.currentInput {
                        context.captureSession.removeInput(currentInput)
                    }

                    // 2. Add Ultra Wide device
                    let ultraWideInput = try AVCaptureDeviceInput(device: ultraWideDevice)
                    if context.captureSession.canAddInput(ultraWideInput) {
                        context.captureSession.addInput(ultraWideInput)

                        Task { @MainActor in
                            context.updateDeviceInput(ultraWideInput)
                        }

                        // Reconfigure video output connection
                        self.configureVideoOutputConnection(context: context)

                        // 3. Configure Ultra Wide for macro focusing
                        DeviceConfigurationHelper.configureSafely(ultraWideDevice) { dev in
                            if dev.isFocusModeSupported(.continuousAutoFocus) {
                                dev.focusMode = .continuousAutoFocus
                            }

                            if dev.isAutoFocusRangeRestrictionSupported {
                                dev.autoFocusRangeRestriction = .none
                            }

                            if dev.isFocusPointOfInterestSupported {
                                dev.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                            }
                        }

                        Task { @MainActor in
                            context.updateRotationCoordinator(ultraWideDevice)
                            macroManager.setActive(true, preMacroZoom: currentZoom)

                            // Disable Portrait mode (Ultra Wide doesn't support hardware depth)
                            portraitManager.disablePortraitMode()

                            // Restart observers
                            context.restartObservers(ultraWideDevice)

                        }
                    } else {
                        throw CameraError.sessionConfigurationFailed
                    }

                    context.captureSession.commitConfiguration()

                    // Apply zoom after commit (so zoom crop and lens switch happen during blackout)
                    let targetZoom = self.config.macro.ultraWideZoomFactor
                    let clampedZoom = DeviceConfigurationHelper.clampZoom(targetZoom, for: ultraWideDevice)
                    DeviceConfigurationHelper.setZoom(clampedZoom, on: ultraWideDevice)

                    Task { @MainActor in
                        context.updateZoom(clampedZoom)
                    }

                } catch {
                    context.captureSession.commitConfiguration()
                    self.logger.error("Failed to activate macro mode: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Deactivates macro mode by switching back to Triple Camera
    /// - Parameters:
    ///   - tripleCameraDevice: The Triple Camera device to switch back to
    ///   - context: Switch context with session references and callbacks
    ///   - macroManager: The macro mode service to update state
    func deactivateMacroMode(
        tripleCameraDevice: AVCaptureDevice,
        context: SwitchContext,
        macroManager: MacroModeService
    ) {
        guard macroManager.isMacroModeActive else { return }


        // Get pre-macro zoom before session queue (avoid MainActor access inside)
        let preMacroZoom = macroManager.getPreMacroZoom()

        // Smooth transition with snapshot overlay
        smoothCameraTransition(previewLayer: context.previewLayer) {
            context.sessionQueue.async { [weak self, context] in
                guard let self = self else { return }

                do {
                    context.captureSession.beginConfiguration()

                    // 1. Remove current input (Ultra Wide)
                    if let currentInput = context.currentInput {
                        context.captureSession.removeInput(currentInput)
                    }

                    // 2. Add Triple Camera
                    let tripleCameraInput = try AVCaptureDeviceInput(device: tripleCameraDevice)
                    if context.captureSession.canAddInput(tripleCameraInput) {
                        context.captureSession.addInput(tripleCameraInput)

                        Task { @MainActor in
                            context.updateDeviceInput(tripleCameraInput)
                        }

                        // Reconfigure video output connection
                        self.configureVideoOutputConnection(context: context)

                        // 3. Configure Triple Camera (focus + zoom together)
                        let clampedZoom = DeviceConfigurationHelper.clampZoom(preMacroZoom, for: tripleCameraDevice)
                        DeviceConfigurationHelper.configureSafely(tripleCameraDevice) { dev in
                            // Restore zoom atomically with lens switch
                            dev.videoZoomFactor = clampedZoom

                            if dev.isFocusModeSupported(.continuousAutoFocus) {
                                dev.focusMode = .continuousAutoFocus
                            }
                        }

                        Task { @MainActor in
                            context.updateRotationCoordinator(tripleCameraDevice)
                            macroManager.setActive(false)
                            context.updateZoom(clampedZoom)

                            // Restart observers
                            context.restartObservers(tripleCameraDevice)

                        }
                    } else {
                        throw CameraError.sessionConfigurationFailed
                    }

                    // Commit configuration (lens switch + zoom atomically)
                    context.captureSession.commitConfiguration()

                } catch {
                    context.captureSession.commitConfiguration()
                    self.logger.error("Failed to deactivate macro mode: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private Methods

    /// Configures video output connection after camera switch
    private nonisolated func configureVideoOutputConnection(context: SwitchContext) {
        guard let videoOutput = context.videoOutput else { return }

        // Ensure delegate is still set
        if videoOutput.sampleBufferDelegate == nil {
            Task { @MainActor in
                if let delegate = context.videoDelegate {
                    videoOutput.setSampleBufferDelegate(delegate, queue: context.videoOutputQueue)
                }
            }
        }

        // Configure video connection
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
    }

    /// Smooth camera transition with snapshot overlay (eliminates flicker)
    nonisolated private func smoothCameraTransition(
        previewLayer: AVCaptureVideoPreviewLayer,
        _ switchAction: @escaping () -> Void
    ) {
        let previewLayerBox = PreviewLayerBox(layer: previewLayer)
        DispatchQueue.main.async { [weak self, previewLayerBox] in
            guard let self = self else { return }
            let previewLayer = previewLayerBox.layer

            // 1. Capture current preview frame as overlay
            guard let currentImage = self.captureCurrentPreviewFrame(from: previewLayer) else {
                // Fallback to simple fade if capture fails
                previewLayer.opacity = 0.0
                switchAction()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [previewLayer] in
                    previewLayer.opacity = 1.0
                }
                return
            }

            // 2. Create snapshot layer
            let snapshotLayer = CALayer()
            snapshotLayer.contents = currentImage
            snapshotLayer.frame = previewLayer.bounds
            snapshotLayer.opacity = 1.0
            previewLayer.addSublayer(snapshotLayer)

            // 3. Execute switch under snapshot
            switchAction()

            // 4. Fade out snapshot to reveal new feed
            DispatchQueue.main.asyncAfter(deadline: .now() + self.config.transition.snapshotFadeDelay) { [weak self] in
                guard let self = self else { return }

                CATransaction.begin()
                CATransaction.setAnimationDuration(self.config.transition.switchAnimationDuration)
                CATransaction.setCompletionBlock {
                    snapshotLayer.removeFromSuperlayer()
                }

                snapshotLayer.opacity = 0.0

                CATransaction.commit()
            }
        }
    }

    /// Captures current preview frame
    private nonisolated func captureCurrentPreviewFrame(from previewLayer: AVCaptureVideoPreviewLayer) -> CGImage? {
        UIGraphicsBeginImageContextWithOptions(previewLayer.bounds.size, false, 0)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        previewLayer.render(in: context)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return image?.cgImage
    }
}
