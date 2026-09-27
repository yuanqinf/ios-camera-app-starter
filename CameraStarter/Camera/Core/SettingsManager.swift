//
//  SettingsManager.swift
//  CameraStarter
//
//  User settings manager - Persisted using UserDefaults
//

import Foundation

/// User settings manager
@Observable
final class SettingsManager {

    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        // Detection
        static let trackingBoxEnabled = "settings.detection.trackingBox"

        // Flash
        static let flashMode = "settings.flashMode"

        // Live Photo
        static let livePhotoEnabled = "settings.livePhotoEnabled"
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
            Keys.trackingBoxEnabled: true,
            Keys.flashMode: "Auto",
            Keys.livePhotoEnabled: false
        ])

        // Load saved values
        trackingBoxEnabled = defaults.bool(forKey: Keys.trackingBoxEnabled)
        flashMode = defaults.string(forKey: Keys.flashMode) ?? "Auto"
        livePhotoEnabled = defaults.bool(forKey: Keys.livePhotoEnabled)
    }
}
