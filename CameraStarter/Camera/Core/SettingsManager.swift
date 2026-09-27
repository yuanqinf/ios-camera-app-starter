//
//  SettingsManager.swift
//  CameraStarter
//
//  User settings manager - Persisted using UserDefaults
//

import Foundation


/// Capture assist mode (Off → Shot Guide)
enum CaptureAssistMode: Int, CaseIterable {
    case off = 0        // No assistance
    case shotGuide = 1  // Show tilt guidance only

    /// Whether shot guide should be shown
    var showsShotGuide: Bool {
        self != .off
    }

    /// Cycle to next mode
    func next() -> CaptureAssistMode {
        let allCases = CaptureAssistMode.allCases
        let currentIndex = allCases.firstIndex(of: self) ?? 0
        let nextIndex = (currentIndex + 1) % allCases.count
        return allCases[nextIndex]
    }

    /// Display name for accessibility
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .shotGuide: return "Shot Guide"
        }
    }
}

/// User settings manager
@Observable
final class SettingsManager {

    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        // Capture Assist Mode
        static let captureAssistMode = "settings.captureAssistMode"

        // Detection
        static let trackingBoxEnabled = "settings.detection.trackingBox"

        // Flash
        static let flashMode = "settings.flashMode"

        // Live Photo
        static let livePhotoEnabled = "settings.livePhotoEnabled"
    }

    // MARK: - Capture Assist Mode

    /// Capture assist mode (off / shotGuide)
    var captureAssistMode: CaptureAssistMode {
        didSet {
            defaults.set(captureAssistMode.rawValue, forKey: Keys.captureAssistMode)
        }
    }

    /// Convenience: whether shot guide should be shown
    var shotGuideEnabled: Bool {
        captureAssistMode.showsShotGuide
    }

    // MARK: - Detection Settings

    /// Tracking box enabled - shows bounding box around tracked subject
    /// Independent feature, works in all camera modes
    var trackingBoxEnabled: Bool {
        didSet {
            defaults.set(trackingBoxEnabled, forKey: Keys.trackingBoxEnabled)
        }
    }

    // MARK: - Flash Settings

    /// Flash mode (off / on / auto)
    var flashMode: String {
        didSet {
            defaults.set(flashMode, forKey: Keys.flashMode)
        }
    }

    // MARK: - Live Photo Settings

    /// Live Photo enabled toggle
    var livePhotoEnabled: Bool {
        didSet {
            defaults.set(livePhotoEnabled, forKey: Keys.livePhotoEnabled)
        }
    }

    // MARK: - Initialization

    private init() {
        // Register default values
        // Note: Advanced features default to OFF for new users
        defaults.register(defaults: [
            Keys.captureAssistMode: CaptureAssistMode.off.rawValue,
            Keys.trackingBoxEnabled: true,
            Keys.flashMode: "Auto",
            Keys.livePhotoEnabled: false
        ])

        // Load saved values
        trackingBoxEnabled = defaults.bool(forKey: Keys.trackingBoxEnabled)
        flashMode = defaults.string(forKey: Keys.flashMode) ?? "Auto"
        livePhotoEnabled = defaults.bool(forKey: Keys.livePhotoEnabled)

        // Capture assist mode always resets to off on app launch
        captureAssistMode = .off
    }
}
