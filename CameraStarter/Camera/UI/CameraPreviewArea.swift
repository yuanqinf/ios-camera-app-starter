//
//  CameraPreviewArea.swift
//  CameraStarter
//
//  Camera preview layer with all overlays and gestures
//  Extracted from CameraView for better separation of concerns
//

import SwiftUI
import AVFoundation

struct CameraPreviewArea: View {
    // MARK: - Dependencies

    @Bindable var model: CameraModel
    let settings: SettingsManager
    let selectedAspectRatio: AspectRatio
    let selectedCameraMode: CameraMode
    let uiRotationAngle: Angle
    let showFreezeFrame: Bool
    let showTabTransitionOverlay: Bool
    let showPrivacyScreen: Bool
    let showShutterFlash: Bool

    // MARK: - Bindings

    @Binding var manualFocusPoint: CGPoint?
    @Binding var showManualFocusIndicator: Bool
    @Binding var selectedZoom: CGFloat
    @Binding var previewOpacity: Double
    @Binding var isPinching: Bool
    @Binding var showPinchZoomOverlay: Bool
    @Binding var pinchZoomHideTask: Task<Void, Never>?

    // MARK: - Callbacks

    var onFocusTap: ((CGPoint) -> Void)?

    // MARK: - Constants

    private let videoModeCornerRadius: CGFloat = 24
    private let zoomConversionFactor: CGFloat = 2.0
    private let maxUIZoom: CGFloat = 5.0
    private var maxDeviceZoom: CGFloat { maxUIZoom * zoomConversionFactor }

    // MARK: - Private State

    @State private var pinchStartZoom: CGFloat = 1.0

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let basePreviewHeight = screenWidth * 16.0 / 9.0

            ZStack {
                // Camera preview layer
                PreviewView(previewLayer: model.camera.previewLayer, aspectRatio: selectedAspectRatio)
                    .frame(width: screenWidth, height: basePreviewHeight)
                    .clipped()
                    .opacity(previewOpacity)
                    .clipShape(videoModeClipShape)

                // Black overlay for mode switching
                if showFreezeFrame {
                    Color.black
                        .frame(width: screenWidth, height: basePreviewHeight)
                        .clipShape(videoModeClipShape)
                }

                // Tab switch transition overlay
                if showTabTransitionOverlay {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .transition(.opacity)
                }

                // Privacy protection overlay (App Switcher)
                if showPrivacyScreen {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                }

                // Aspect ratio mask
                AspectRatioMaskView(
                    aspectRatio: selectedAspectRatio,
                    containerWidth: screenWidth,
                    containerHeight: basePreviewHeight
                )

                // Frame corner decorations
                FrameCornerOverlay(
                    aspectRatio: selectedAspectRatio,
                    containerWidth: screenWidth,
                    containerHeight: basePreviewHeight,
                    isHidden: selectedCameraMode == .video
                )
                .padding(1)

                // Subject tracking overlay
                if settings.trackingBoxEnabled {
                    SubjectTrackingOverlay(
                        lockService: model.camera.subjectLockService,
                        containerSize: CGSize(width: screenWidth, height: basePreviewHeight),
                        maskHeight: selectedAspectRatio.maskHeight(
                            containerWidth: screenWidth,
                            containerHeight: basePreviewHeight
                        )
                    )
                    .transaction { $0.animation = nil }
                }

                // Manual focus indicator
                if showManualFocusIndicator, let point = manualFocusPoint {
                    FocusIndicator(position: point, state: .focusing)
                        .id("manual-\(point.x)-\(point.y)")
                }

                // Shutter flash effect
                if showShutterFlash {
                    Color.appBlack
                        .transition(.opacity)
                }

                // Timer countdown overlay
                if model.timer.isCountingDown {
                    TimerCountdownView(remainingSeconds: model.timer.remainingSeconds)
                        .transition(.opacity)
                }

                // Pinch-to-zoom value overlay (back camera only)
                if !model.camera.isFrontCamera && showPinchZoomOverlay {
                    PinchZoomOverlay(
                        zoomFactor: model.camera.currentZoomFactor / zoomConversionFactor,
                        isVisible: true,
                        rotationAngle: uiRotationAngle
                    )
                }
            }
            .frame(width: screenWidth, height: basePreviewHeight)
            .clipped()
            .contentShape(Rectangle())
            .animation(AppAnimation.imageFade, value: model.timer.isCountingDown)
            .animation(AppAnimation.slow, value: selectedAspectRatio)
            .onTapGesture { location in
                let maskH = selectedAspectRatio.maskHeight(
                    containerWidth: screenWidth,
                    containerHeight: basePreviewHeight
                )
                let visibleTop = maskH
                let visibleBottom = basePreviewHeight - maskH
                guard location.y >= visibleTop && location.y <= visibleBottom else { return }
                onFocusTap?(location)
            }
            .gesture(pinchToZoomGesture)
            .accessibilityElement()
            .accessibilityLabel("View Finder")
            .accessibilityAddTraits([.isImage])
            .accessibilityHint("Tap to focus, pinch to zoom")
        }
    }

    // MARK: - Video Mode Clip Shape

    private var videoModeClipShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: model.camera.cameraMode == .video ? videoModeCornerRadius : 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: model.camera.cameraMode == .video ? videoModeCornerRadius : 0
        )
    }

    // MARK: - Pinch-to-Zoom Gesture

    private var pinchToZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard !model.camera.isFrontCamera else { return }

                if !isPinching {
                    isPinching = true
                    pinchStartZoom = model.camera.currentZoomFactor
                    pinchZoomHideTask?.cancel()
                    showPinchZoomOverlay = true
                }

                let scaleFactor = value
                let newDeviceZoom = pinchStartZoom * scaleFactor
                let deviceMin = model.camera.minZoomFactor
                let deviceMax = min(model.camera.maxZoomFactor, maxDeviceZoom)
                let clampedZoom = min(max(newDeviceZoom, deviceMin), deviceMax)

                model.camera.setZoom(clampedZoom)
                selectedZoom = clampedZoom / zoomConversionFactor
            }
            .onEnded { _ in
                guard !model.camera.isFrontCamera else { return }

                isPinching = false
                snapToNearestPreset(from: model.camera.currentZoomFactor)

                pinchZoomHideTask?.cancel()
                pinchZoomHideTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        withAnimation {
                            showPinchZoomOverlay = false
                        }
                    }
                }

                Haptics.light()
            }
    }

    private func snapToNearestPreset(from deviceZoom: CGFloat) {
        let devicePresets = model.camera.availablePresetZooms.map { $0 * zoomConversionFactor }
        guard let nearestPreset = devicePresets.min(by: { abs($0 - deviceZoom) < abs($1 - deviceZoom) }) else { return }

        let distance = abs(nearestPreset - deviceZoom)
        let snapThreshold = nearestPreset * 0.15
        if distance <= snapThreshold && distance > 0.01 {
            model.camera.setZoom(nearestPreset, animated: true)
            selectedZoom = nearestPreset / zoomConversionFactor
            Haptics.selection()
        }
    }
}
