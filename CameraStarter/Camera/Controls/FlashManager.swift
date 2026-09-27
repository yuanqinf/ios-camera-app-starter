//
//  FlashManager.swift
//  CameraStarter
//
//  Flash manager - Controls flash modes
//

import AVFoundation


/// Flash mode
enum FlashMode: String, CaseIterable {
    case off = "Off"
    case on = "On"
    case auto = "Auto"

    var systemFlashMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off:
            return .off
        case .on:
            return .on
        case .auto:
            return .auto
        }
    }

    /// Icon name (SF Symbols)
    var iconName: String {
        switch self {
        case .off:
            return "bolt.slash.fill"
        case .on:
            return "bolt.fill"
        case .auto:
            return "bolt.badge.automatic.fill"
        }
    }

    /// Accessibility label for VoiceOver
    var accessibilityLabel: String {
        switch self {
        case .off:
            return "Off"
        case .on:
            return "On"
        case .auto:
            return "Auto"
        }
    }
}

/// Flash manager
final class FlashManager {

    private let settings = SettingsManager.shared

    /// Current flash mode (persisted)
    private(set) var currentMode: FlashMode {
        didSet {
            settings.flashMode = currentMode.rawValue
        }
    }

    init() {
        // Load persisted flash mode
        currentMode = FlashMode(rawValue: settings.flashMode) ?? .auto
    }

    /// Check if device supports flash
    /// - Parameter device: Camera device
    /// - Returns: Whether flash is supported
    func isFlashAvailable(on device: AVCaptureDevice) -> Bool {
        return device.hasFlash && device.isFlashAvailable
    }

    /// Check if photo output supports specified flash mode
    /// - Parameters:
    ///   - mode: Flash mode
    ///   - photoOutput: Photo output object
    /// - Returns: Whether the mode is supported
    func isFlashModeSupported(_ mode: FlashMode, on photoOutput: AVCapturePhotoOutput) -> Bool {
        return photoOutput.supportedFlashModes.contains(mode.systemFlashMode)
    }

    /// Set flash mode
    /// - Parameter mode: Flash mode
    func setFlashMode(_ mode: FlashMode) {
        currentMode = mode
    }

    /// Get icon name for current mode
    func getCurrentIcon() -> String {
        return currentMode.iconName
    }
}
