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

    /// Button press.
    static let buttonSpring = Animation.spring(response: 0.3, dampingFraction: 0.6)

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

extension Color {
    static let appPrimaryColor = Color(hex: 0xEA4335)
    static let appSecondaryColor = Color(hex: 0xF28B82)

    static let appBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 1)
            : UIColor(red: 249/255, green: 244/255, blue: 239/255, alpha: 1)
    })

    static let appSecondaryBackground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .secondarySystemBackground
            : UIColor(red: 239/255, green: 236/255, blue: 234/255, alpha: 1)
    })

    static var appCardBackground: Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.12, alpha: 1)
                : UIColor(white: 0.98, alpha: 1)
        })
    }

    static let appPrimaryText = Color(UIColor.label)
    static let appSecondaryText = Color(UIColor.secondaryLabel)
    static let appDivider = Color(UIColor.separator)

    static let appBlack = Color(hex: 0x000000)
    static let appDarkGray = Color(hex: 0x1C1C1E)

    static let appSuccess = Color(hex: 0x34C759)
    static let appError = Color(hex: 0xFF453A)

    /// A color from a 0xRRGGBB integer.
    init(hex: Int, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

// MARK: - Button style

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(AppAnimation.buttonSpring, value: configuration.isPressed)
    }
}
