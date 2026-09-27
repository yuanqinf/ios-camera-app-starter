//
//  ZoomManager.swift
//  CameraStarter
//
//  Provides camera zoom control functionality
//

@preconcurrency import AVFoundation
import os.log

/// Manager for camera zoom control
@MainActor
final class ZoomManager {

    // MARK: - Public Properties

    /// Current zoom factor
    private(set) var currentZoomFactor: CGFloat = 1.0

    /// Minimum zoom factor
    private(set) var minZoomFactor: CGFloat = 1.0

    /// Maximum zoom factor
    private(set) var maxZoomFactor: CGFloat = 10.0

    /// Available preset zoom levels (for UI buttons)
    /// Initial value directly uses config to avoid UI display delay
    private(set) var availablePresetZooms: [CGFloat] = CameraConfiguration.shared.zoom.presetZoomLevels

    /// Whether current camera is front-facing
    private(set) var isFrontCamera: Bool = false

    // MARK: - Private Properties

    private let config = CameraConfiguration.shared
    private let sessionQueue: DispatchQueue
    private let logger = Logger(subsystem: Log.subsystem, category: "ZoomManager")

    // MARK: - Initialization

    init(sessionQueue: DispatchQueue) {
        self.sessionQueue = sessionQueue
    }

    // MARK: - Public Methods

    /// Sets zoom factor on device
    /// - Parameters:
    ///   - factor: Target zoom factor
    ///   - device: Camera device
    ///   - animated: Whether to animate the zoom transition (default: false)
    func setZoom(_ factor: CGFloat, on device: AVCaptureDevice, animated: Bool = false) {
        sessionQueue.async { [weak self, device] in
            guard let self = self else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                // Clamp zoom factor to device limits
                let clampedFactor = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)

                // Cancel any ongoing ramp
                device.cancelVideoZoomRamp()

                if animated {
                    // Smooth animated zoom (for snap-to-preset)
                    device.ramp(toVideoZoomFactor: clampedFactor, withRate: 8.0)
                } else {
                    // Set zoom directly (fast switching, no smooth transition)
                    device.videoZoomFactor = clampedFactor
                }

                // Update current zoom factor on main thread
                Task { @MainActor in
                    self.currentZoomFactor = clampedFactor
                }
            } catch {
                self.logger.error("Failed to set zoom: \(error.localizedDescription)")
            }
        }
    }

    /// Updates zoom capabilities for device
    /// - Parameters:
    ///   - device: Camera device
    ///   - isFront: Whether this is a front-facing camera
    func updateCapabilities(for device: AVCaptureDevice, isFront: Bool = false) {
        self.isFrontCamera = isFront
        self.minZoomFactor = device.minAvailableVideoZoomFactor
        self.maxZoomFactor = device.maxAvailableVideoZoomFactor

        // Fixed preset buttons (like iPhone native camera)
        self.availablePresetZooms = config.zoom.presetZoomLevels
    }

    /// Updates current zoom factor (for synchronization)
    func updateCurrentZoom(_ factor: CGFloat) {
        self.currentZoomFactor = factor
    }
}
