//
//  TimerCountdownView.swift
//  CameraStarter
//
//  Timer countdown overlay for camera
//

import SwiftUI

/// Countdown overlay displayed during timer countdown
struct TimerCountdownView: View {
    let remainingSeconds: Int

    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 1.0

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.3)

            // Countdown number
            Text("\(remainingSeconds)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
                .contentTransition(.numericText())
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .onChange(of: remainingSeconds) { oldValue, newValue in
            // Reset animation state
            scale = 1.3
            opacity = 0.0

            // Animate in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }

            // Play haptic feedback for final 3 seconds
            if newValue <= 3 && newValue > 0 {
                let generator = UIImpactFeedbackGenerator(style: newValue == 1 ? .heavy : .medium)
                generator.impactOccurred()
            }
        }
        .onAppear {
            // Initial animation
            scale = 1.3
            opacity = 0.0

            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                scale = 1.0
                opacity = 1.0
            }
        }
    }
}

// MARK: - Preview

#Preview("Countdown 3") {
    ZStack {
        Color.gray
        TimerCountdownView(remainingSeconds: 3)
    }
}

#Preview("Countdown 1") {
    ZStack {
        Color.gray
        TimerCountdownView(remainingSeconds: 1)
    }
}
