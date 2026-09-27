//
//  ShutterButton.swift
//  CameraStarter
//
//  Shutter button for camera photo capture
//

import SwiftUI

struct ShutterButton: View {
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            Haptics.medium()

            withAnimation(.easeOut(duration: 0.1)) {
                isPressed = true
            }

            action()

            DispatchQueue.mainAfter(AppDuration.fast) {
                withAnimation(.easeIn(duration: 0.1)) {
                    isPressed = false
                }
            }
        }) {
            ZStack {
                // Outer ring - white (native camera style)
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 64, height: 64)

                // Inner circle - white
                Circle()
                    .fill(Color.white)
                    .frame(width: 54, height: 54)
                    .scaleEffect(isPressed ? 0.9 : 1.0)

                // Flash when pressed
                if isPressed {
                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 54, height: 54)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take Photo")
        .accessibilityHint("Double tap to capture a photo")
    }
}
