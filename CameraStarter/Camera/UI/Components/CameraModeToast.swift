//
//  CameraModeToast.swift
//  CameraStarter
//
//  Quick toast for camera mode changes (Capture Assist)
//  Appears briefly in the center of the screen
//

import SwiftUI

// MARK: - Camera Mode Toast Message

struct CameraModeToastMessage: Equatable {
    let id: String  // Unique identifier for Equatable
    /// An SF Symbol name.
    let icon: String
    let text: String
    let gradient: LinearGradient?

    static func == (lhs: CameraModeToastMessage, rhs: CameraModeToastMessage) -> Bool {
        lhs.id == rhs.id
    }

    /// Shot Guide mode
    static var shotGuide: CameraModeToastMessage {
        CameraModeToastMessage(
            id: "shotGuide",
            icon: "level",
            text: "camera.mode.shot.guide".localized,
            gradient: nil
        )
    }

    /// Capture Assist off
    static var captureAssistOff: CameraModeToastMessage {
        CameraModeToastMessage(
            id: "captureAssistOff",
            icon: "level",
            text: "camera.mode.assist.off".localized,
            gradient: nil
        )
    }
}

// MARK: - Camera Mode Toast View

struct CameraModeToast: View {
    let message: CameraModeToastMessage

    /// Whether this is an active mode (not off)
    private var isActiveMode: Bool {
        message.id != "captureAssistOff"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Yellow for active modes, white for off
            Image(systemName: message.icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 20, height: 20)
                .foregroundColor(isActiveMode ? .yellow : .white.opacity(0.8))

            Text(message.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.5))
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Camera Mode Toast Modifier

struct CameraModeToastModifier: ViewModifier {
    @Binding var message: CameraModeToastMessage?
    let duration: TimeInterval

    @State private var workItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .center) {
                if let message = message {
                    CameraModeToast(message: message)
                        .padding(.bottom, 80)  // Offset up from center to account for bottom bar
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: message)
            .onChange(of: message) { oldValue, newValue in
                if newValue != nil {
                    scheduleHide()
                }
            }
    }

    private func scheduleHide() {
        workItem?.cancel()
        let task = DispatchWorkItem {
            withAnimation {
                message = nil
            }
        }
        workItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}

// MARK: - View Extension

extension View {
    /// Show a quick camera mode toast in the center of the view
    func cameraModeToast(_ message: Binding<CameraModeToastMessage?>, duration: TimeInterval = 1.2) -> some View {
        modifier(CameraModeToastModifier(message: message, duration: duration))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 20) {
            CameraModeToast(message: .captureAssistOff)
            CameraModeToast(message: .shotGuide)
        }
    }
}
