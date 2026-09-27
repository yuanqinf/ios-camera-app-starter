//
//  CameraTopControlsBar.swift
//  CameraStarter
//
//  Top control bar for camera view
//  Contains flash/torch, live photo, timer, and settings controls
//

import SwiftUI

/// Top control bar for camera view
struct CameraTopControlsBar: View {
    // MARK: - Properties
    let isLivePhotoEnabled: Bool

    // MARK: - State from CameraManager
    let cameraMode: CameraMode
    let isRecording: Bool
    let recordingDuration: TimeInterval
    let isFlashAvailable: Bool
    let flashMode: FlashMode
    let isTorchEnabled: Bool
    let rotationAngle: Angle

    // MARK: - Timer Controls
    let isTimerEnabled: Bool
    let timerDuration: TimerDuration

    // MARK: - Callbacks
    let onToggleFlash: () -> Void
    let onToggleTorch: () -> Void
    let onToggleLivePhoto: () -> Void
    let onCycleTimer: () -> Void

    var body: some View {
        ZStack {
            // Center: Recording duration (Video mode only)
            centerContent

            // Left and Right controls
            HStack(alignment: .center) {
                // Left controls
                leftControls

                Spacer()

                // Right controls
                rightControls
            }
        }
        .padding(.horizontal, 20)
        .animation(.easeInOut(duration: 0.3), value: flashMode)
        .animation(.easeInOut(duration: 0.3), value: cameraMode)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }

    // MARK: - Center Content

    @ViewBuilder
    private var centerContent: some View {
        if cameraMode == .video && isRecording {
            // Video mode: Show recording duration when recording
            RecordingDurationView(
                duration: recordingDuration
            )
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Left Controls

    private var leftControls: some View {
        HStack(spacing: 12) {
            if cameraMode == .video {
                // Video mode: Torch button
                torchButton
            } else {
                // Photo mode: Flash button
                if isFlashAvailable {
                    flashButton
                }
            }
        }
    }

    // MARK: - Right Controls

    private var rightControls: some View {
        HStack(spacing: 12) {
            // Timer Button (Photo mode only)
            if cameraMode == .photo {
                timerButton
            }

            // Live Photo Button (Photo mode only)
            if cameraMode == .photo {
                livePhotoButton
            }
        }
    }

    // MARK: - Button Views

    private var flashButton: some View {
        Button {
            onToggleFlash()
            Haptics.light()
        } label: {
            Image(systemName: flashMode.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(flashColor)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(flashBackgroundColor)
                )
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
        }
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Flash")
        .accessibilityValue(flashMode.accessibilityLabel)
        .accessibilityHint("Double tap to change flash mode")
    }

    private var torchButton: some View {
        Button {
            onToggleTorch()
            Haptics.light()
        } label: {
            Image(systemName: isTorchEnabled ? "bolt.fill" : "bolt.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(isTorchEnabled ? .appCameraActive : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(isTorchEnabled ? Color.appCameraActive.opacity(0.25) : .black.opacity(0.7))
                )
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Torch")
        .accessibilityValue(isTorchEnabled ? "On" : "Off")
        .accessibilityHint("Double tap to toggle flashlight")
    }

    private var livePhotoButton: some View {
        Button {
            onToggleLivePhoto()
            Haptics.light()
        } label: {
            Image(systemName: isLivePhotoEnabled ? "livephoto" : "livephoto.slash")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(isLivePhotoEnabled ? .appCameraActive : .white.opacity(0.7))
                .frame(width: 32, height: 32)
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Live Photo")
        .accessibilityValue(isLivePhotoEnabled ? "On" : "Off")
        .accessibilityHint("Double tap to toggle Live Photo")
    }

    private var timerButton: some View {
        ZStack(alignment: .topTrailing) {
            // Main timer button
            Button {
                onCycleTimer()
                Haptics.light()
            } label: {
                Group {
                    if isTimerEnabled {
                        // Timer enabled: show duration
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)

                            Text("\(timerDuration.rawValue)s")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.appCameraActive)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    } else {
                        // Timer disabled: show off icon only
                        Image(systemName: "timer")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 32, height: 32)
                    }
                }
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.7))
                )
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isTimerEnabled ? "Timer \(timerDuration.displayText)" : "Timer Off")
            .accessibilityHint("Tap to change timer duration")
        }
        .animation(.easeInOut(duration: 0.2), value: isTimerEnabled)
    }

    // MARK: - Color Helpers

    private var flashColor: Color {
        switch flashMode {
        case .off:
            return .white
        case .on:
            return .appCameraActive
        case .auto:
            return .appCameraActive
        }
    }

    private var flashBackgroundColor: Color {
        switch flashMode {
        case .off:
            return .black.opacity(0.7)
        case .on:
            return .appCameraActive.opacity(0.25)
        case .auto:
            return .black.opacity(0.7)
        }
    }
}
