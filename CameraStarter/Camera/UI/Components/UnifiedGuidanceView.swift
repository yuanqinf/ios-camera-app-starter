//
//  UnifiedGuidanceView.swift
//  CameraStarter
//
//  Unified guidance view that displays a single guidance message
//  Supports landscape orientation with auto-rotation
//

import SwiftUI

/// Unified guidance view
struct UnifiedGuidanceView: View {
    let message: UnifiedGuidanceMessage

    /// Device rotation angle for landscape support
    var rotationAngle: Double = 0

    /// Display text
    private var displayText: String {
        message.text
    }

    /// Whether to show angle hint (for tilt up/down messages)
    private var shouldShowAngleHint: Bool {
        message == .tiltDown || message == .tiltUp
    }

    /// Angle hint text
    private var angleHintText: String {
        "guidance.angle.hint".localized
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: message.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(message.state.color)
                    .symbolEffect(.bounce, value: message.state == .ready)

                Text(displayText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.7))
                    .overlay(
                        Capsule()
                            .strokeBorder(message.state.color.opacity(0.5), lineWidth: 1.5)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

            // Angle hint for tilt messages
            if shouldShowAngleHint {
                Text(angleHintText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.6))
                    )
                    .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .rotationEffect(.degrees(rotationAngle))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayText)
        .accessibilityHint(accessibilityHint)
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    private var accessibilityHint: String {
        switch message.state {
        case .searching:
            return "guidance.hint.searching".localized
        case .adjusting:
            return "guidance.hint.adjusting".localized
        case .preparing:
            return "guidance.hint.preparing".localized
        case .ready:
            return "guidance.hint.ready".localized
        }
    }
}

// MARK: - Preview

#Preview("Find Subject") {
    ZStack {
        Color.black
        UnifiedGuidanceView(message: .findSubject)
    }
}

#Preview("Tilt Down") {
    ZStack {
        Color.black
        UnifiedGuidanceView(message: .tiltDown)
    }
}

#Preview("Perfect") {
    ZStack {
        Color.black
        UnifiedGuidanceView(message: .perfect)
    }
}

#Preview("Landscape") {
    ZStack {
        Color.black
        UnifiedGuidanceView(message: .stepBack, rotationAngle: 90)
    }
}
