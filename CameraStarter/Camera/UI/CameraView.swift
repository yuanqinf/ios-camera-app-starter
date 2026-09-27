//
//  CameraView.swift
//  CameraStarter
//
//  Camera main interface - Enhanced focus version
//  Supports tap to focus + auto recovery + haptic feedback + shutter feedback
//

import SwiftUI
import os.log
import CoreMotion
import AVFoundation

struct CameraView: View {
    private let logger = Logger(subsystem: Log.subsystem, category: "CameraView")

    // MARK: - Data Model (passed from parent to ensure single instance)
    /// Camera data model - must be passed from parent view to prevent recreation
    @Bindable var model: DataModel

    // MARK: - Tab mode support
    /// Whether this camera view is the currently active tab (controls session start/stop)
    var isActiveTab: Bool = true
    /// Binding to notify parent whether camera preview is active (not on permission screen)
    var isCameraReady: Binding<Bool>?

    @Environment(\.scenePhase) private var scenePhase  // Monitor app lifecycle
    @Environment(\.openURL) private var openURL

    // Note: SettingsManager is @Observable, but we use @State here because:
    // 1. It's a shared singleton that manages its own state
    // 2. Using @State allows onChange to detect changes properly
    // 3. @StateObject would cause recreation issues with shared singletons
    @State private var settings = SettingsManager.shared
    @State private var thumbnailUpdateTrigger = 0
    @State private var manualFocusPoint: CGPoint?
    @State private var showManualFocusIndicator = false

    // Shutter feedback animation
    @State private var showShutterFlash = false

    // Subject attention sound button animation
    @State private var isSoundButtonPressed = false

    // Aspect ratio
    @State private var selectedAspectRatio: AspectRatio = .ratio4_3

    // Subject detection bounding boxes (supports multiple subjects)
    @State private var currentSubjectDetections: [SubjectDetectionResult] = []

    // Privacy protection mask (App Switcher black screen)
    @State private var showPrivacyScreen = false

    // Zoom control
    @State private var selectedZoom: CGFloat = 1.0
    @State private var previewOpacity: Double = 1.0  // Preview layer opacity (for zoom transition animation)

    // Pinch-to-zoom state (back camera only)
    @State private var isPinching: Bool = false
    @State private var pinchStartZoom: CGFloat = 1.0  // Starting device zoom when pinch begins
    @State private var showPinchZoomOverlay: Bool = false
    @State private var pinchZoomHideTask: Task<Void, Never>? = nil

    // Error state
    @State private var cameraError: CameraError?
    @State private var showErrorAlert = false

    // Camera permission state (show permission view when not authorized)
    @State private var showPermissionView = false

    // Camera startup state tracking
    @State private var hasStartedCamera = false

    // Tab switch transition overlay (hides stale preview frame)
    @State private var showTabTransitionOverlay = false

    // Thumbnail feedback animation
    @State private var thumbnailFeedbackType: ThumbnailFeedbackType?

    // Camera mode (Photo/Video)
    @State private var selectedCameraMode: CameraMode = .photo

    // Saved aspect ratio (restored when switching back to photo mode)
    @State private var savedAspectRatioForPhotoMode: AspectRatio?

    // Mode switching freeze frame (shows last frame during reconfiguration for smooth transition)
    @State private var showFreezeFrame: Bool = false

    // Block capture during mode switching to prevent accidental photos
    @State private var isModeSwitchingInProgress: Bool = false

    // Task for delayed unblock of capture (can be cancelled on new mode switch)
    @State private var modeSwitchUnblockTask: Task<Void, Never>?

    // Toast message for permission errors
    @State private var toastMessage: ToastMessage?

    // Landscape detection and rotation angle (uses CMMotionManager, works even with rotation lock enabled)
    @State private var devicePhysicalOrientation: UIDeviceOrientation = .portrait
    private let orientationMotionManager = CMMotionManager()

    // Orientation detection stability control
    @State private var orientationStabilityCount: Int = 0
    @State private var pendingOrientation: UIDeviceOrientation?

    // Calculate UI element rotation angle (based on physical device orientation)
    private var uiRotationAngle: Angle {
        switch devicePhysicalOrientation {
        case .landscapeLeft:
            return .degrees(90)
        case .landscapeRight:
            return .degrees(-90)
        case .portraitUpsideDown:
            return .degrees(180)
        default:
            return .zero
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                // Calculate layout dimensions
                let screenWidth = geometry.size.width
                let previewCenterY: CGFloat = 345
                let bottomControlsHeight: CGFloat = {
                    if #available(iOS 26, *) { return 225 } else { return 320 }
                }()

                ZStack {
                    // Background color extends to safe area
                    Color.appBlack.ignoresSafeArea()

                    if showPermissionView {
                        // Camera permission not yet granted - show permission flow
                        CameraPermissionView {
                            // Permission granted - start camera
                            showPermissionView = false
                            Task {
                                do {
                                    try await model.camera.start()
                                    hasStartedCamera = true
                                    await setupCameraAfterStart()
                                } catch {
                                    logger.error("❌ Camera start after permission: \(error.localizedDescription)")
                                }
                            }
                        }
                    } else {
                        // Preview area (16:9 container, shows different ratios through masking)
                        CameraPreviewArea(
                            model: model,
                            settings: settings,
                            selectedAspectRatio: selectedAspectRatio,
                            selectedCameraMode: selectedCameraMode,
                            uiRotationAngle: uiRotationAngle,
                            showFreezeFrame: showFreezeFrame,
                            showTabTransitionOverlay: showTabTransitionOverlay,
                            showPrivacyScreen: showPrivacyScreen,
                            showShutterFlash: showShutterFlash,
                            manualFocusPoint: $manualFocusPoint,
                            showManualFocusIndicator: $showManualFocusIndicator,
                            selectedZoom: $selectedZoom,
                            previewOpacity: $previewOpacity,
                            isPinching: $isPinching,
                            showPinchZoomOverlay: $showPinchZoomOverlay,
                            pinchZoomHideTask: $pinchZoomHideTask,
                            onFocusTap: { location in handleFocusTap(at: location) }
                        )
                        .position(x: screenWidth / 2, y: previewCenterY)

                        // Control bars (fixed position, always on top layer)
                        VStack(spacing: 0) {
                            topControlsBar
                                .frame(height: 40)
                                .background(model.camera.cameraMode == .video ? Color.clear : Color.appBlack)

                            Spacer()

                            CameraBottomBar(
                                model: model,
                                settings: settings,
                                uiRotationAngle: uiRotationAngle,
                                devicePhysicalOrientation: devicePhysicalOrientation,
                                selectedCameraMode: $selectedCameraMode,
                                selectedAspectRatio: $selectedAspectRatio,
                                selectedZoom: $selectedZoom,
                                previewOpacity: $previewOpacity,
                                isModeSwitchingInProgress: $isModeSwitchingInProgress,
                                showFreezeFrame: $showFreezeFrame,
                                thumbnailFeedbackType: $thumbnailFeedbackType,
                                savedAspectRatioForPhotoMode: $savedAspectRatioForPhotoMode,
                                modeSwitchUnblockTask: $modeSwitchUnblockTask,
                                toastMessage: $toastMessage,
                                onTakePhoto: { handleTakePhoto() },
                                onOpenGallery: openPhotosApp
                            )
                            .frame(height: bottomControlsHeight)
                            .background(Color.clear)
                        }
                    }
                }
            }
            .onChange(of: showPermissionView) { _, newValue in
                isCameraReady?.wrappedValue = !newValue
            }
            .task(id: isActiveTab) {
                // Only start camera when this tab is active
                guard isActiveTab else { return }

                // Check camera permission first
                let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

                // Show permission view for notDetermined or denied
                if cameraStatus != .authorized {
                    logger.info("📷 Camera permission not authorized (\(String(describing: cameraStatus))) - showing permission view")
                    showPermissionView = true
                    showTabTransitionOverlay = false
                    return
                }

                // Permission is authorized - start camera
                do {
                    try await model.camera.start()
                    hasStartedCamera = true  // Mark camera as successfully started
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.easeInOut(duration: 1)) {
                        isCameraReady?.wrappedValue = true
                    }
                    await setupCameraAfterStart()

                    // Fade out tab transition overlay after camera starts
                    // Small delay to ensure preview frame is ready
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation(.easeOut(duration: 0.25)) {
                        showTabTransitionOverlay = false
                    }
                } catch {
                    logger.error("❌ Camera start failed: \(error.localizedDescription)")
                    cameraError = .startFailed(error.localizedDescription)
                    showErrorAlert = true
                    showTabTransitionOverlay = false
                }
            }
            .onDisappear {
                // Stop orientation monitoring and camera (modal dismiss or view destruction)
                orientationMotionManager.stopDeviceMotionUpdates()
                model.timer.cancelCountdown()
                model.camera.stop()
                // Dismiss welcome toast when switching views
                toastMessage = nil
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onChange(of: selectedAspectRatio) { oldRatio, newRatio in
                // Sync aspect ratio to CameraManager (for photo cropping)
                model.camera.selectedAspectRatio = newRatio
            }
            .onChange(of: model.camera.isFrontCamera) { wasFront, isFront in
                // Sync selectedZoom to default value when switching cameras
                // Back camera: device 2.0x → UI 1x
                // Front camera: device 1.0x
                selectedZoom = model.camera.currentZoomFactor / 2.0
            }
            .onChange(of: isActiveTab) { wasActive, isActive in
                // Handle tab becoming inactive - stop camera to save resources
                // Note: Restart is handled by .task(id: isActiveTab)
                if !isActive {
                    model.timer.cancelCountdown()
                    model.camera.stop()
                    // Show overlay immediately when leaving (no animation)
                    showTabTransitionOverlay = true
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .statusBar(hidden: selectedCameraMode == .video)  // Hide in video mode for immersive experience
            .alert("camera.error.title".localized, isPresented: $showErrorAlert, presenting: cameraError) { error in
                Button("common.ok".localized) {
                    showErrorAlert = false
                }
            } message: { error in
                VStack(alignment: .leading, spacing: 8) {
                    if let description = error.errorDescription {
                        Text(description)
                    }
                    if let suggestion = error.recoverySuggestion {
                        Text(suggestion)
                            .font(.caption)
                    }
                }
            }
            .toast($toastMessage)
        }
    }


    // MARK: - Photo Capture Handling

    private func handleTakePhoto() {
        // Block capture during mode switching
        guard !isModeSwitchingInProgress else { return }

        // Only allow photo capture in photo mode
        guard model.camera.cameraMode == .photo else { return }

        // If timer is counting down, ignore additional taps
        if model.timer.isCountingDown {
            return
        }

        // If timer is enabled, start countdown
        if model.timer.isEnabled {
            model.timer.startCountdown(
                onCapture: { [self] in
                    executeCapture()
                }
            )
            return
        }

        // No timer, capture immediately
        executeCapture()
    }

    /// Execute the actual photo capture with shutter animation
    private func executeCapture() {
        // Block capture during mode switching
        guard !isModeSwitchingInProgress else { return }

        // Double-check we're in photo mode before capturing
        guard model.camera.cameraMode == .photo else { return }

        // 1. Trigger shutter flash animation (black flash, simulates shutter closing)
        withAnimation(AppAnimation.shutterFlash) {
            showShutterFlash = true
        }

        // 2. Execute actual photo capture
        model.camera.takePhoto()

        // 3. Restore screen (shutter opens)
        DispatchQueue.mainAfter(AppDuration.shutterFlash) {
            withAnimation(.easeIn(duration: 0.06)) {
                showShutterFlash = false
            }
        }
    }


    // MARK: - Subject Detection

    private func setupSubjectDetection() {
        // Setup SubjectDetector subject detection callback (for the tracking boxes and tap-to-lock)
        // Note: SwiftUI Views are structs (value types), so no weak self needed
        model.camera.subjectDetector.onSubjectsDetected = { subjectResults, primaryID in
            Task { @MainActor in
                // Update subject lock service FIRST and outside withAnimation
                // to prevent SwiftUI animation transaction from leaking into tracking box updates
                self.model.camera.subjectLockService.update(with: subjectResults, primaryID: primaryID)

                withAnimation(AppAnimation.imageFade) {
                    self.currentSubjectDetections = subjectResults
                }
            }
        }
    }

    /// Setup callbacks for photo/video saves
    /// Note: Photo import to subject gallery is handled by PhotoLibraryObserver (AI-based matching)
    private func setupPhotoAutoImport() {
        model.onPhotoSaved = { [weak model] assetID in
            Task { @MainActor in
                model?.updateThumbnailAssetID(assetID)
            }
        }

        model.onVideoSaved = { [weak model] assetID in
            Task { @MainActor in
                model?.updateThumbnailAssetID(assetID)
            }
        }

        // Photo saved feedback: green border flash (for all photos)
        model.onPhotoThumbnailUpdated = {
            Task { @MainActor in
                self.showThumbnailFeedback(.saved)
            }
        }

    }

    /// Show thumbnail feedback animation
    private func showThumbnailFeedback(_ type: ThumbnailFeedbackType) {
        withAnimation(.easeInOut(duration: 0.15)) {
            thumbnailFeedbackType = type
        }

        // Haptic feedback
        switch type {
        case .saved:
            Haptics.success()
        case .discarded:
            Haptics.warning()
        }

        // Auto-clear after animation
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.2)) {
                thumbnailFeedbackType = nil
            }
        }
    }

    // MARK: - Photos

    /// Open the system Photos app, where the shots just taken are.
    ///
    /// There is no documented way to open Photos. `photos-redirect://` is the
    /// scheme Photos itself answers to and has for many releases; if a future
    /// iOS drops it, the tap does nothing rather than fail. Leaving for Photos
    /// sends the app to the background, so the scene-phase handling below
    /// stops the session on the way out and restarts it, with a fresh
    /// thumbnail, on the way back.
    private func openPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else { return }
        openURL(url)
    }

    // MARK: - App Lifecycle Handling

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Only restart camera if:
            // 1. Camera was previously started
            // 2. This camera view is the active tab
            guard hasStartedCamera, isActiveTab else {
                // Still need to hide privacy screen even if not restarting camera
                withAnimation(.easeOut(duration: 0.2)) {
                    showPrivacyScreen = false
                }
                return
            }
            // Smooth transition: fade out privacy blur while camera restarts
            // No need for separate transition overlay - the blur fades out naturally
            Task {
                do {
                    try await model.camera.start()
                    // Reload thumbnail in case photos were deleted externally (e.g., in Photos app)
                    await model.loadLatestThumbnail()

                    // Wait briefly for camera preview to stabilize, then fade out blur
                    try? await Task.sleep(nanoseconds: 150_000_000)  // 0.15 seconds
                    withAnimation(.easeOut(duration: 0.25)) {
                        showPrivacyScreen = false
                    }
                } catch {
                    logger.error("❌ Camera restart failed: \(error.localizedDescription)")
                    cameraError = .restartFailed(error.localizedDescription)
                    showErrorAlert = true
                    showPrivacyScreen = false
                }
            }

        case .inactive:
            // App enters inactive state (e.g., swipe up preview, control center)
            // Immediately show blur overlay to protect privacy (for App Switcher screenshot)
            showPrivacyScreen = true
            model.timer.cancelCountdown()
            model.camera.stop()

        case .background:
            // App fully enters background
            showPrivacyScreen = true
            model.timer.cancelCountdown()
            model.camera.stop()

        @unknown default:
            break
        }
    }

    // MARK: - Focus Handling

    private func handleFocusTap(at location: CGPoint) {
        // Haptic feedback
        Haptics.light()

        // Calculate preview bounds for subject detection hit test
        let screenWidth = UIScreen.main.bounds.width
        let previewHeight = screenWidth * 16.0 / 9.0
        let previewBounds = CGRect(x: 0, y: 0, width: screenWidth, height: previewHeight)

        // Check if tap is on a subject and handle lock/unlock
        let selectedSubject = model.camera.handleTapWithSubjectSelection(
            at: location,
            currentDetections: currentSubjectDetections,
            previewBounds: previewBounds
        )

        // Always execute focus at tap location
        model.camera.focus(at: location)

        // Show manual focus indicator
        manualFocusPoint = location
        showManualFocusIndicator = true

        // Different feedback based on whether a subject was selected
        if selectedSubject != nil {
            // Subject was selected - stronger feedback
            Haptics.medium()
        }

        // Hide manual indicator after 2 seconds (matches FocusIndicator animation duration)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
            withAnimation {
                showManualFocusIndicator = false
                manualFocusPoint = nil
            }
        }
    }

    // MARK: - Top Control Bar

    private var topControlsBar: some View {
        CameraTopControlsBar(
            isLivePhotoEnabled: settings.livePhotoEnabled,
            cameraMode: selectedCameraMode,
            isRecording: model.camera.isRecording,
            recordingDuration: model.camera.recordingDuration,
            isFlashAvailable: model.camera.isFlashAvailable,
            flashMode: model.camera.flashMode,
            isTorchEnabled: model.camera.isTorchEnabled,
            rotationAngle: uiRotationAngle,
            isTimerEnabled: model.timer.isEnabled,
            timerDuration: model.timer.duration,
            onToggleFlash: {
                model.camera.toggleFlashMode()
            },
            onToggleTorch: {
                model.camera.toggleTorch()
            },
            onToggleLivePhoto: {
                withAnimation(AppAnimation.standard) {
                    settings.livePhotoEnabled.toggle()
                    // Live Photo and Portrait are mutually exclusive
                    if settings.livePhotoEnabled && model.camera.captureMode == .portrait {
                        model.camera.setPortraitMode(enabled: false)
                    }
                    // Update camera manager
                    model.camera.setLivePhotoEnabled(settings.livePhotoEnabled)
                }
            },
            onCycleTimer: {
                model.timer.cycleDuration()
            }
        )
        .animation(.easeInOut(duration: 0.3), value: model.camera.isMacroModeActive)
        .animation(.easeInOut(duration: 0.3), value: model.camera.isInMacroFocusRange)
    }

    // MARK: - Helper Methods

    /// Open iOS Settings app to this app's settings page
    // MARK: - Device Orientation Monitoring (using CMMotionManager)

    /// Start device physical orientation monitoring (works even with rotation lock enabled)
    /// Uses Apple-style detection: hysteresis thresholds + motion stability check
    private func startOrientationMonitoring() {
        guard orientationMotionManager.isDeviceMotionAvailable else {
            logger.warning("⚠️ Device motion not available")
            return
        }

        orientationMotionManager.deviceMotionUpdateInterval = 0.2  // 5Hz update rate (orientation changes are slow)
        orientationMotionManager.startDeviceMotionUpdates(to: .main) { [self] motion, error in
            guard let motion = motion else { return }

            let gravity = motion.gravity
            let x = gravity.x
            let y = gravity.y

            // Check if device is relatively still (low rotation rate = stable)
            let rotationRate = motion.rotationRate
            let rotationMagnitude = sqrt(
                rotationRate.x * rotationRate.x +
                rotationRate.y * rotationRate.y +
                rotationRate.z * rotationRate.z
            )
            let isDeviceStable = rotationMagnitude < 0.3  // rad/s threshold

            // Calculate device angle using atan2 (relative to portrait orientation)
            let angle = atan2(x, -y) * 180 / .pi

            // Apple-style hysteresis: different thresholds for entering vs exiting orientation
            // Enter landscape: need to tilt past 55°
            // Exit landscape (return to portrait): need to come back within 40°
            let enterThreshold: Double = 55
            let exitThreshold: Double = 40

            let newOrientation: UIDeviceOrientation
            switch devicePhysicalOrientation {
            case .portrait:
                // Currently portrait - need to pass enterThreshold to switch
                if angle >= enterThreshold && angle < 180 - enterThreshold {
                    newOrientation = .landscapeRight
                } else if angle <= -enterThreshold && angle > -(180 - enterThreshold) {
                    newOrientation = .landscapeLeft
                } else if abs(angle) >= 180 - enterThreshold {
                    newOrientation = .portraitUpsideDown
                } else {
                    newOrientation = .portrait
                }

            case .landscapeRight:
                // Currently landscape right - use exitThreshold to return
                if angle < exitThreshold && angle > -exitThreshold {
                    newOrientation = .portrait
                } else if angle >= enterThreshold && angle < 180 - enterThreshold {
                    newOrientation = .landscapeRight
                } else if angle <= -enterThreshold {
                    newOrientation = .landscapeLeft
                } else if abs(angle) >= 180 - enterThreshold {
                    newOrientation = .portraitUpsideDown
                } else {
                    newOrientation = .landscapeRight  // Stay in current
                }

            case .landscapeLeft:
                // Currently landscape left - use exitThreshold to return
                if angle < exitThreshold && angle > -exitThreshold {
                    newOrientation = .portrait
                } else if angle <= -enterThreshold && angle > -(180 - enterThreshold) {
                    newOrientation = .landscapeLeft
                } else if angle >= enterThreshold {
                    newOrientation = .landscapeRight
                } else if abs(angle) >= 180 - enterThreshold {
                    newOrientation = .portraitUpsideDown
                } else {
                    newOrientation = .landscapeLeft  // Stay in current
                }

            case .portraitUpsideDown:
                // Currently upside down - use exitThreshold to return
                if abs(angle) < 180 - exitThreshold {
                    if angle >= enterThreshold {
                        newOrientation = .landscapeRight
                    } else if angle <= -enterThreshold {
                        newOrientation = .landscapeLeft
                    } else {
                        newOrientation = .portrait
                    }
                } else {
                    newOrientation = .portraitUpsideDown  // Stay in current
                }

            default:
                newOrientation = .portrait
            }

            // Only switch orientation when device is stable
            guard isDeviceStable else {
                // Device is moving, reset stability count
                orientationStabilityCount = 0
                pendingOrientation = nil
                return
            }

            // Stability filtering: requires consecutive frames detecting same orientation
            let stabilityThreshold = 2  // ~0.4s at 5Hz

            if newOrientation == devicePhysicalOrientation {
                orientationStabilityCount = 0
                pendingOrientation = nil
            } else if newOrientation == pendingOrientation {
                orientationStabilityCount += 1

                if orientationStabilityCount >= stabilityThreshold {
                    devicePhysicalOrientation = newOrientation
                    orientationStabilityCount = 0
                    pendingOrientation = nil
                }
            } else {
                pendingOrientation = newOrientation
                orientationStabilityCount = 1
            }
        }
    }

    // MARK: - Camera Setup After Permission

    /// Setup camera after successful start (extracted for reuse after permission grant)
    private func setupCameraAfterStart() async {
        await model.loadPhotos()
        await model.loadLatestThumbnail()

        // Setup subject detection callback
        setupSubjectDetection()

        // Setup photo save callback, auto add to gallery
        setupPhotoAutoImport()

        // Sync zoom state (device zoom to UI zoom)
        // Device 2.0x → UI 1x
        selectedZoom = model.camera.currentZoomFactor / 2.0


        // Sync Live Photo state from persisted settings
        model.camera.setLivePhotoEnabled(settings.livePhotoEnabled)

        // Start physical device orientation detection (uses CMMotionManager, works even with rotation lock enabled)
        startOrientationMonitoring()
    }

}


#Preview {
    CameraView(model: DataModel())
}
