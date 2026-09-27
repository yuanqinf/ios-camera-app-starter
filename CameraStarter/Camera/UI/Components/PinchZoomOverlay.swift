//
//  PinchZoomOverlay.swift
//  CameraStarter
//
//  Real-time zoom value display during pinch-to-zoom gesture
//

import SwiftUI

/// Displays the current zoom value during pinch-to-zoom gesture
struct PinchZoomOverlay: View {
    /// Current zoom factor (in UI terms, e.g., 1.0 = 1×)
    let zoomFactor: CGFloat

    /// Whether the overlay is visible
    let isVisible: Bool

    /// Rotation angle for landscape mode
    var rotationAngle: Angle = .zero

    var body: some View {
        if isVisible {
            Text(zoomText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.5))
                )
                .rotationEffect(rotationAngle)
        }
    }

    /// Format zoom value for display (e.g., "2.3×")
    private var zoomText: String {
        if zoomFactor < 1.0 {
            // Show decimal for values less than 1 (e.g., ".5×" or "0.7×")
            if zoomFactor == 0.5 {
                return ".5×"
            }
            return String(format: "%.1f×", zoomFactor)
        } else if zoomFactor.truncatingRemainder(dividingBy: 1.0) == 0 {
            // Whole number (e.g., "2×")
            return String(format: "%.0f×", zoomFactor)
        } else {
            // Decimal (e.g., "2.3×")
            return String(format: "%.1f×", zoomFactor)
        }
    }
}

#Preview {
    ZStack {
        Color.appBlack.ignoresSafeArea()

        VStack(spacing: 20) {
            PinchZoomOverlay(zoomFactor: 0.5, isVisible: true)
            PinchZoomOverlay(zoomFactor: 1.0, isVisible: true)
            PinchZoomOverlay(zoomFactor: 2.3, isVisible: true)
            PinchZoomOverlay(zoomFactor: 3.0, isVisible: true)
        }
    }
}
