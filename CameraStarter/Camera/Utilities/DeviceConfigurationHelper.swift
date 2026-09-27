//
//  DeviceConfigurationHelper.swift
//  CameraStarter
//
//  Centralized helper for AVCaptureDevice configuration
//  Eliminates repeated lock/unlock patterns across camera services
//

import AVFoundation


/// Helper for safe AVCaptureDevice configuration with automatic lock/unlock
/// All methods are nonisolated to allow calling from any context (session queues, etc.)
enum DeviceConfigurationHelper {

    // MARK: - Core Configuration

    /// Safely configure a device with automatic lock/unlock
    /// - Parameters:
    ///   - device: The camera device to configure
    ///   - action: Configuration closure
    /// - Throws: Any error from locking or the action closure
    nonisolated static func configure(_ device: AVCaptureDevice, _ action: (AVCaptureDevice) throws -> Void) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        try action(device)
    }

    /// Safely configure a device, logging errors instead of throwing
    /// - Parameters:
    ///   - device: The camera device to configure
    ///   - action: Configuration closure
    /// - Returns: True if configuration succeeded
    @discardableResult
    nonisolated static func configureSafely(_ device: AVCaptureDevice, _ action: (AVCaptureDevice) -> Void) -> Bool {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            action(device)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Zoom Helpers

    /// Clamp zoom factor to device limits
    nonisolated static func clampZoom(_ zoom: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    /// Set zoom factor with automatic clamping
    nonisolated static func setZoom(_ zoom: CGFloat, on device: AVCaptureDevice) {
        let clampedZoom = clampZoom(zoom, for: device)
        configureSafely(device) { $0.videoZoomFactor = clampedZoom }
    }

}
