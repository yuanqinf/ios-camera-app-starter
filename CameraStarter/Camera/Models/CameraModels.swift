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
            return "Camera permission is required to take photos. Please allow camera access in Settings."
        case .deviceNotAvailable:
            return "Camera device is unavailable. Please make sure no other app is using the camera."
        case .sessionConfigurationFailed:
            return "Camera configuration failed. Please restart the app and try again."
        case .startFailed(let message):
            return "Unable to start camera: \(message)"
        case .restartFailed(let message):
            return "Unable to restart camera: \(message)"
        case .focusFailed(let message):
            return "Focus failed: \(message)"
        case .captureFailed(let message):
            return "Capture failed: \(message)"
        case .macroModeFailed(let message):
            return "Macro mode failed: \(message)"
        case .coordinateConversionFailed:
            return "Coordinate conversion failed"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Please allow camera access in Settings."
        case .deviceNotAvailable:
            return "Please make sure no other app is using the camera."
        case .sessionConfigurationFailed, .startFailed, .restartFailed:
            return "Please restart the app and try again."
        case .focusFailed:
            return "Please tap another area on the screen to refocus."
        case .captureFailed:
            return "Please press the capture button again."
        case .macroModeFailed:
            return "Please try adjusting the distance between the camera and the subject."
        case .coordinateConversionFailed:
            return "Please tap another area on the screen."
        case .unknown:
            return "If the problem persists, please contact support."
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

