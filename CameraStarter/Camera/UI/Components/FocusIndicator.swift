//
//  FocusIndicator.swift
//  CameraStarter
//
//  Focus indicator - iPhone style
//  Supports two states: focusing (yellow) and focus locked (green)
//

import SwiftUI

/// Focus state
enum FocusIndicatorState {
    case focusing  // Focusing - yellow
    case locked    // Focus locked - green
}

struct FocusIndicator: View {
    let position: CGPoint
    let state: FocusIndicatorState

    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(indicatorColor, lineWidth: 2)
            .frame(width: 80, height: 80)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(position)
            .onAppear {
                // Scale animation
                withAnimation(.easeOut(duration: 0.3)) {
                    scale = 1.0
                }

                // Determine display duration based on state
                let displayDuration: TimeInterval = state == .focusing ? 2.0 : 1.5

                // Fade out after displaying for a period of time
                DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        opacity = 0
                    }
                }
            }
    }

    private var indicatorColor: Color {
        switch state {
        case .focusing:
            return .yellow  // Focusing - yellow
        case .locked:
            return .green   // Focus locked - green
        }
    }
}

#Preview("Focusing") {
    ZStack {
        Color.appBlack.ignoresSafeArea()
        FocusIndicator(position: CGPoint(x: 200, y: 300), state: .focusing)
    }
}

#Preview("Focus Locked") {
    ZStack {
        Color.appBlack.ignoresSafeArea()
        FocusIndicator(position: CGPoint(x: 200, y: 300), state: .locked)
    }
}
