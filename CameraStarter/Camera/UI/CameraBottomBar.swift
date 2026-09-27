//
//  CameraBottomBar.swift
//  CameraStarter
//
//  Camera bottom controls: shot controls, Photos button, shutter, camera flip
//  Extracted from CameraView for better separation of concerns
//

import SwiftUI
import AVFoundation

struct CameraBottomBar: View {
    // MARK: - Dependencies

    @Bindable var model: CameraModel
    let settings: SettingsManager
    let uiRotationAngle: Angle
    let devicePhysicalOrientation: UIDeviceOrientation

    // MARK: - Bindings

    @Binding var selectedCameraMode: CameraMode
    @Binding var selectedAspectRatio: AspectRatio
    @Binding var selectedZoom: CGFloat
    @Binding var previewOpacity: Double
    @Binding var isModeSwitchingInProgress: Bool
    @Binding var showFreezeFrame: Bool
    @Binding var savedAspectRatioForPhotoMode: AspectRatio?
    @Binding var modeSwitchUnblockTask: Task<Void, Never>?
    @Binding var toastMessage: ToastMessage?

    // MARK: - State

    /// Whether the thumbnail is flashing for a photo just taken
    let isThumbnailFlashing: Bool

    // MARK: - Callbacks

    var onTakePhoto: () -> Void
    var onOpenPhotos: () -> Void

    // MARK: - Private State

    @State private var thumbnailUpdateTrigger = 0

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            shotControls
                .padding(.bottom, 16)
                .padding(.top, 60)

            buttonsView
        }
    }

    // MARK: - Shot Controls

    private var shotControls: some View {
        ShotControls(
            selectedMode: $selectedCameraMode,
            selectedZoom: $selectedZoom,
            previewOpacity: $previewOpacity,
            aspectRatio: selectedAspectRatio,
            isFrontCamera: model.camera.isFrontCamera,
            isMacroModeActive: model.camera.isMacroModeActive,
            isMacroSuggested: model.camera.isMacroSuggested,
            onToggleMacro: { model.camera.toggleMacroMode() },
            currentZoomFactor: model.camera.currentZoomFactor,
            availablePresetZooms: model.camera.availablePresetZooms,
            onZoomChange: { deviceZoom in
                model.camera.setZoom(deviceZoom)
            },
            rotationAngle: uiRotationAngle
        )
        .onChange(of: selectedCameraMode) { oldMode, newMode in
            guard oldMode != newMode else { return }

            if newMode == .video {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                switch micStatus {
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        Task { @MainActor in
                            if granted {
                                performModeSwitch(to: newMode)
                            } else {
                                selectedCameraMode = .photo
                                toastMessage = ToastMessage(
                                    message: "permission.microphone.required".localized,
                                    type: .error,
                                    action: ToastAction(title: "common.settings".localized) {
                                        openAppSettings()
                                    }
                                )
                            }
                        }
                    }
                    return
                case .denied, .restricted:
                    selectedCameraMode = .photo
                    toastMessage = ToastMessage(
                        message: "permission.microphone.required".localized,
                        type: .error,
                        action: ToastAction(title: "common.settings".localized) {
                            openAppSettings()
                        }
                    )
                    return
                case .authorized:
                    break
                @unknown default:
                    break
                }
            }

            performModeSwitch(to: newMode)
        }
    }

    // MARK: - Buttons

    private var buttonsView: some View {
        HStack(spacing: 0) {
            // Left: Thumbnail
            photosButton
                .frame(width: 100, alignment: .leading)

            Spacer()

            // Center: Shutter
            shutterButton

            Spacer()

            // Right: Flip camera
            HStack(spacing: 16) {
                if !model.camera.isRecording {
                    switchCameraButton
                }
            }
            .frame(width: 100, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Color.black.opacity(0.6))
    }

    // MARK: - Photos Button

    private var photosButton: some View {
        Button {
            onOpenPhotos()
        } label: {
            ThumbnailView(
                image: model.thumbnail,
                isFlashing: isThumbnailFlashing
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .rotationEffect(uiRotationAngle)
            .animation(.easeInOut(duration: 0.3), value: uiRotationAngle)
            .id(thumbnailUpdateTrigger)
            .transition(.scale.combined(with: .opacity))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("camera.photos".localized)
        .accessibilityHint("Opens the Photos app")
        .onChange(of: model.thumbnail) { oldImage, newImage in
            withAnimation(AppAnimation.thumbnailSpring) {
                thumbnailUpdateTrigger += 1
            }
        }
    }

    // MARK: - Shutter / Record Button

    private var shutterButton: some View {
        Group {
            if selectedCameraMode == .video {
                RecordButton(isRecording: model.camera.isRecording) {
                    handleRecordVideo()
                }
            } else if model.timer.isCountingDown {
                timerCancelButton
            } else {
                ShutterButton {
                    onTakePhoto()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.timer.isCountingDown)
        .animation(.easeInOut(duration: 0.2), value: selectedCameraMode)
    }

    // MARK: - Timer Cancel

    private var timerCancelButton: some View {
        Button {
            model.timer.cancelCountdown()
            Haptics.warning()
        } label: {
            ZStack {
                Circle()
                    .stroke(
                        AngularGradient(colors: [.red, .orange, .red], center: .center),
                        lineWidth: 4
                    )
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color.appDarkGray)
                    .frame(width: 58, height: 58)
                Image(systemName: "xmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Cancel Timer")
    }

    // MARK: - Switch Camera

    private var switchCameraButton: some View {
        Button {
            Haptics.light()
            model.camera.switchCamera()
        } label: {
            ZStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white)
                    .symbolEffect(.bounce, value: model.camera.isFrontCamera)
            }
            .frame(width: 50, height: 50)
            .contentShape(Circle())
            .rotationEffect(uiRotationAngle)
            .animation(.easeInOut(duration: 0.3), value: uiRotationAngle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Switch Camera")
        .accessibilityValue(model.camera.isFrontCamera ? "Front camera" : "Back camera")
    }

    // MARK: - Actions

    private func handleRecordVideo() {
        if model.camera.isRecording {
            model.camera.stopRecording()
        } else {
            model.camera.startRecording()
        }
    }

    private func performModeSwitch(to newMode: CameraMode) {
        Haptics.selection()

        modeSwitchUnblockTask?.cancel()
        modeSwitchUnblockTask = nil
        isModeSwitchingInProgress = true
        selectedZoom = 1.0

        withAnimation(.easeOut(duration: 0.15)) {
            showFreezeFrame = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)

            if newMode == .video {
                if selectedAspectRatio != .ratio16_9 {
                    savedAspectRatioForPhotoMode = selectedAspectRatio
                }
                selectedAspectRatio = .ratio16_9

                if settings.livePhotoEnabled {
                    settings.livePhotoEnabled = false
                    model.camera.setLivePhotoEnabled(false)
                }
            } else {
                if let savedRatio = savedAspectRatioForPhotoMode {
                    selectedAspectRatio = savedRatio
                    savedAspectRatioForPhotoMode = nil
                }
            }

            model.camera.setCameraMode(newMode) {
                modeSwitchUnblockTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }

                    withAnimation(.easeIn(duration: 0.2)) {
                        showFreezeFrame = false
                    }

                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    isModeSwitchingInProgress = false
                }
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
