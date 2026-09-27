//
//  Theme.swift
//  CameraStarter
//
//  Animations, haptics, timing and colors shared across the camera UI.
//

import SwiftUI
import UIKit

// MARK: - Animation

enum AppAnimation {
    /// Standard transitions: menu toggles, most UI changes.
    static let standard = Animation.easeInOut(duration: 0.25)

    /// Deliberate changes: aspect ratio, focus indicator.
    static let slow = Animation.easeInOut(duration: 0.3)

    /// The thumbnail swapping in after a capture.
    static let thumbnailSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)

    /// An image fading in.
    static let imageFade = Animation.easeOut(duration: 0.2)

    /// The shutter flash.
    static let shutterFlash = Animation.easeOut(duration: 0.08)
}

// MARK: - Timing

/// Delays for DispatchQueue, matched to the animations above.
enum AppDuration {
    static let fast: TimeInterval = 0.15
    static let shutterFlash: TimeInterval = 0.08
}

extension DispatchQueue {
    /// Run on the main queue after a delay.
    static func mainAfter(_ delay: TimeInterval, execute: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
    }

    /// Run a work item on the main queue after a delay.
    static func mainAfter(_ delay: TimeInterval, execute: DispatchWorkItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
    }
}

// MARK: - Haptics

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Colors
//
// Every color here is one of the system's own, so the app follows light and
// dark mode and Increase Contrast the way Apple's apps do. The accent is the
// AccentColor asset (the system blue until you give it a value), which views
// pick up through `.tint` and `Color.accentColor`.

extension Color {
    /// A screen, and the cards grouped on it, as in Settings.
    static let appBackground = Color(uiColor: .systemGroupedBackground)
    static let appCardBackground = Color(uiColor: .secondarySystemGroupedBackground)

    /// Fill for a placeholder, like the thumbnail of an empty album.
    static let appSecondaryBackground = Color(uiColor: .secondarySystemBackground)

    static let appPrimaryText = Color(uiColor: .label)
    static let appSecondaryText = Color(uiColor: .secondaryLabel)

    static let appSuccess = Color(uiColor: .systemGreen)
    static let appError = Color(uiColor: .systemRed)

    /// A camera control that's switched on (flash, torch, Live Photo, macro,
    /// the selected zoom) and focus in progress. Yellow, as in the Camera app.
    static let appCameraActive = Color(uiColor: .systemYellow)

    /// Behind the camera, in any appearance.
    static let appBlack = Color.black

    /// Controls set on that black: the system's darkest gray, as dark mode
    /// draws it, whatever the appearance.
    static let appDarkGray = Color(uiColor: UIColor.systemGray6.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .dark)
    ))
}
