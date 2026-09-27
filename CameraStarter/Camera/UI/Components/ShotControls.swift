//
//  ShotControls.swift
//  CameraStarter
//
//  Shot controls: zoom controls, mode switch button, and macro toggle
//

import SwiftUI

struct ShotControls: View {
    @Binding var selectedMode: CameraMode
    @Binding var selectedZoom: CGFloat
    @Binding var previewOpacity: Double

    // Aspect ratio for conditional bottom padding
    var aspectRatio: AspectRatio = .ratio4_3

    // Macro controls (photo mode only)
    var isFrontCamera: Bool = false
    var isMacroModeActive: Bool = false
    var isMacroSuggested: Bool = false
    var onToggleMacro: (() -> Void)?

    // Zoom controls
    var currentZoomFactor: CGFloat = 1.0
    var availablePresetZooms: [CGFloat] = [0.5, 1.0, 2.0]
    var onZoomChange: ((CGFloat) -> Void)?

    // Rotation angle for device orientation
    var rotationAngle: Angle = .zero

    var body: some View {
        HStack {
            // Left: Macro mode button (back camera only, photo mode only)
            Group {
                if !isFrontCamera && selectedMode == .photo && (isMacroModeActive || isMacroSuggested) {
                    macroModeButton
                } else {
                    Color.clear.frame(width: 36, height: 36)
                }
            }

            Spacer()

            // Center: Zoom controls
            zoomControls

            Spacer()

            // Right: Mode switch button
            modeSwitchButton
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Zoom Controls

    /// Whether zoom control should be disabled (front camera in video mode)
    private var isZoomDisabled: Bool {
        isFrontCamera && selectedMode == .video
    }

    private let zoomControlsHeight: CGFloat = 44

    @ViewBuilder
    private var zoomControls: some View {
        Group {
            if isZoomDisabled {
                // Front camera + video mode: no zoom control
                Color.clear
            } else if isFrontCamera {
                // Front camera (photo mode): simplified zoom control
                FrontCameraZoomSlider(
                    currentZoom: Binding(
                        get: { currentZoomFactor },
                        set: { _ in }
                    ),
                    onZoomChange: { deviceZoom in
                        withAnimation(.easeOut(duration: 0.15)) {
                            previewOpacity = 0.6
                        }
                        onZoomChange?(deviceZoom)
                        withAnimation(.easeIn(duration: 0.15).delay(0.08)) {
                            previewOpacity = 1.0
                        }
                    }
                )
                .onTapGesture { }
            } else {
                // Back camera: multiple preset buttons
                ZoomControl(
                    selectedZoom: $selectedZoom,
                    availableZooms: availablePresetZooms,
                    rotationAngle: rotationAngle,
                    onZoomChange: { uiZoom in
                        let deviceZoom = uiZoom * 2.0
                        withAnimation(.easeOut(duration: 0.15)) {
                            previewOpacity = 0.6
                        }
                        onZoomChange?(deviceZoom)
                        withAnimation(.easeIn(duration: 0.15).delay(0.08)) {
                            previewOpacity = 1.0
                        }
                    }
                )
                .onTapGesture { }
            }
        }
        .frame(height: zoomControlsHeight)
    }

    // MARK: - Mode Switch Button

    private var modeSwitchButton: some View {
        Button {
            selectedMode = selectedMode == .photo ? .video : .photo
            Haptics.selection()
        } label: {
            // Show the OTHER mode icon (the one to switch to)
            let targetMode = selectedMode == .photo ? CameraMode.video : CameraMode.photo
            Image(systemName: targetMode.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.5))
                )
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedMode == .photo ? "Switch to Video mode" : "Switch to Photo mode")
        .accessibilityHint("Double tap to switch camera mode")
    }

    // MARK: - Macro Mode Button

    private var macroModeButton: some View {
        Button {
            onToggleMacro?()
            Haptics.light()
        } label: {
            Image(systemName: "camera.macro")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isMacroModeActive ? .appCameraActive : .white.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(isMacroModeActive ? Color.appCameraActive.opacity(0.25) : Color.black.opacity(0.5))
                )
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Macro Mode")
        .accessibilityValue(isMacroModeActive ? "On" : "Off")
        .accessibilityHint("Double tap to toggle macro mode for close-up photos")
    }

}

// MARK: - CameraMode Extension

extension CameraMode {
    var iconName: String {
        switch self {
        case .photo:
            return "video.fill"
        case .video:
            return "camera.fill"
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 60) {
            ShotControls(
                selectedMode: .constant(.photo),
                selectedZoom: .constant(1.0),
                previewOpacity: .constant(1.0)
            )
            ShotControls(
                selectedMode: .constant(.video),
                selectedZoom: .constant(1.0),
                previewOpacity: .constant(1.0)
            )
        }
    }
}
