//
//  RecordButton.swift
//  CameraStarter
//
//  Video recording button - Native camera style
//  White outer ring, red circle when idle, red square when recording
//

import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    // Animation state
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            Haptics.medium()

            withAnimation(.easeOut(duration: 0.1)) {
                isPressed = true
            }

            action()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.easeIn(duration: 0.1)) {
                    isPressed = false
                }
            }
        }) {
            ZStack {
                // Outer ring - white
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 68, height: 68)

                // Inner shape (circle or square)
                if isRecording {
                    // Recording: red square with rounded corners
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                        .scaleEffect(isPressed ? 0.85 : 1.0)
                } else {
                    // Idle: red circle
                    Circle()
                        .fill(Color.red)
                        .frame(width: 58, height: 58)
                        .scaleEffect(isPressed ? 0.9 : 1.0)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
        .accessibilityHint(isRecording ? "Double tap to stop recording" : "Double tap to start recording video")
    }
}

// MARK: - Recording Duration Display

struct RecordingDurationView: View {
    let duration: TimeInterval
    var rotationAngle: Angle = .zero

    var body: some View {
        HStack(spacing: 6) {
            // Red recording indicator dot
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)

            // Duration text
            Text(formattedDuration)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
        .rotationEffect(rotationAngle)
        .animation(.easeInOut(duration: 0.3), value: rotationAngle)
    }

    private var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 40) {
            RecordButton(isRecording: false) {}
            RecordButton(isRecording: true) {}

            RecordingDurationView(duration: 65)
            RecordingDurationView(duration: 3725) // 1:02:05
        }
    }
}
