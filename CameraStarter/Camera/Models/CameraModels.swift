//
//  CameraModels.swift
//  CameraStarter
//
//  Camera models, errors, states, and settings
//

import Foundation

// MARK: - Camera Error

/// Camera error types
enum CameraError: Error, LocalizedError, Equatable {
    case permissionDenied
    case deviceNotAvailable
    case sessionConfigurationFailed
    case startFailed(String)
    case restartFailed(String)
    case focusFailed(String)
    case captureFailed(String)
    case macroModeFailed(String)
    case coordinateConversionFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Camera permission is required to take photos. Please allow camera access in Settings.")
        case .deviceNotAvailable:
            return String(localized: "Camera device is unavailable. Please make sure no other app is using the camera.")
        case .sessionConfigurationFailed:
            return String(localized: "Camera configuration failed. Please restart the app and try again.")
        case .startFailed(let message):
            return String(localized: "Unable to start camera: \(message)")
        case .restartFailed(let message):
            return String(localized: "Unable to restart camera: \(message)")
        case .focusFailed(let message):
            return String(localized: "Focus failed: \(message)")
        case .captureFailed(let message):
            return String(localized: "Capture failed: \(message)")
        case .macroModeFailed(let message):
            return String(localized: "Macro mode failed: \(message)")
        case .coordinateConversionFailed:
            return String(localized: "Coordinate conversion failed")
        case .unknown(let message):
            return String(localized: "Unknown error: \(message)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return String(localized: "Please allow camera access in Settings.")
        case .deviceNotAvailable:
            return String(localized: "Please make sure no other app is using the camera.")
        case .sessionConfigurationFailed, .startFailed, .restartFailed:
            return String(localized: "Please restart the app and try again.")
        case .focusFailed:
            return String(localized: "Please tap another area on the screen to refocus.")
        case .captureFailed:
            return String(localized: "Please press the capture button again.")
        case .macroModeFailed:
            return String(localized: "Please try adjusting the distance between the camera and the subject.")
        case .coordinateConversionFailed:
            return String(localized: "Please tap another area on the screen.")
        case .unknown:
            return String(localized: "If the problem persists, please contact support.")
        }
    }

    static func == (lhs: CameraError, rhs: CameraError) -> Bool {
        switch (lhs, rhs) {
        case (.permissionDenied, .permissionDenied),
             (.deviceNotAvailable, .deviceNotAvailable),
             (.sessionConfigurationFailed, .sessionConfigurationFailed),
             (.coordinateConversionFailed, .coordinateConversionFailed):
            return true
        case (.startFailed(let lMsg), .startFailed(let rMsg)),
             (.restartFailed(let lMsg), .restartFailed(let rMsg)),
             (.focusFailed(let lMsg), .focusFailed(let rMsg)),
             (.captureFailed(let lMsg), .captureFailed(let rMsg)),
             (.macroModeFailed(let lMsg), .macroModeFailed(let rMsg)),
             (.unknown(let lMsg), .unknown(let rMsg)):
            return lMsg == rMsg
        default:
            return false
        }
    }
}

// MARK: - Camera State

/// Camera state
enum CameraState: Equatable {
    case initializing           // Initializing
    case checkingPermissions    // Checking permissions
    case permissionDenied       // Permission denied
    case configuring            // Configuring
    case ready                  // Ready
    case running                // Running
    case failed(CameraError)    // Failed

    var description: String {
        switch self {
        case .initializing:
            return "Initializing..."
        case .checkingPermissions:
            return "Checking permissions..."
        case .permissionDenied:
            return "Camera permission required"
        case .configuring:
            return "Configuring camera..."
        case .ready:
            return "Ready"
        case .running:
            return "Running"
        case .failed(let error):
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Camera Device

/// Camera device (front/back)
enum CameraDevice: String, CaseIterable {
    case back = "Back"
    case front = "Front"
}

