//
//  FrontCameraZoomSlider.swift
//  CameraStarter
//
//  Front camera zoom control - Mimics native camera style
//  Single button, uses zoom in/out icons, tap to toggle
//

import SwiftUI

/// Front camera zoom control (native camera style)
/// Displays as a single button, uses zoom in/out icons, tap to toggle zoom in/out
struct FrontCameraZoomSlider: View {
    /// Current zoom factor (actual device magnification)
    @Binding var currentZoom: CGFloat

    /// Zoom change callback
    let onZoomChange: (CGFloat) -> Void

    /// Minimum zoom (widest, default)
    private let minZoom: CGFloat = 1.0

    /// Maximum zoom (slightly zoomed, matches native camera ~23-24mm equivalent focal length)
    /// Native camera front zoom range is smaller, about 1.3x-1.4x
    private let maxZoom: CGFloat = 1.4

    /// Button pressed state
    @State private var isPressed = false

    /// Whether in zoomed in state
    private var isZoomedIn: Bool {
        currentZoom > 1.2
    }

    var body: some View {
        Button {
            toggleZoom()
        } label: {
            Image(systemName: isZoomedIn ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .fill(Color.black.opacity(0.2))
                        )
                )
                .scaleEffect(isPressed ? 0.9 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isZoomedIn ? "Zoom out" : "Zoom in")
        .accessibilityHint("Tap to toggle between wide and zoomed view")
    }

    /// Toggle zoom
    private func toggleZoom() {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Press animation
        withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) {
            isPressed = true
        }

        // Toggle zoom in/out
        let newZoom: CGFloat
        if isZoomedIn {
            // Currently zoomed in, switch to wide angle
            newZoom = minZoom
        } else {
            // Currently wide angle, switch to zoomed in
            newZoom = maxZoom
        }

        // Update state
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            currentZoom = newZoom
        }

        // Execute zoom
        onZoomChange(newZoom)

        // Restore button state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                isPressed = false
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 40) {
            // Wide angle state (shows zoom in icon)
            FrontCameraZoomSlider(
                currentZoom: .constant(1.0),
                onZoomChange: { _ in }
            )

            // Zoomed in state (shows zoom out icon)
            FrontCameraZoomSlider(
                currentZoom: .constant(1.4),
                onZoomChange: { _ in }
            )
        }
    }
}
