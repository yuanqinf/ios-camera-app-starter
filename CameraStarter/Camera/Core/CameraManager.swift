//
//  CameraManager.swift
//  CameraStarter
//
//  Owns the capture session and the camera's state. This file holds the
//  state, setup and teardown; the work is split by job across:
//
//    CameraManager+Session  starting, stopping, configuring, switching cameras
//    CameraManager+Photo    flash, capture settings, photo delegate callbacks
//    CameraManager+Video    photo/video mode, recording, torch
//    CameraManager+Zoom     zoom, macro, Portrait's depth check
//    CameraManager+Focus    tap to focus, subject lock, preview frames
//

@preconcurrency import AVFoundation
import os.log
import UIKit
import CoreLocation

// MARK: - Video Recording Types

/// Camera mode (Photo/Video)
enum CameraMode: String, CaseIterable {
    case photo
    case video
}

/// Video stabilization mode
enum VideoStabilizationMode: String, CaseIterable {
    case standard    // Standard stabilization
    case action      // Action mode (enhanced stabilization)

}

@Observable
final class CameraManager: NSObject {

    // MARK: - Public Properties

    /// Current state
    var state: CameraState = .initializing

    /// Current camera (front/back)
    var currentDevice: CameraDevice = .back

    /// Whether camera is running
    var isRunning = false

    /// Whether camera is currently starting (to prevent concurrent start calls)
    var isStarting = false

    // MARK: - Video Recording Properties

    /// Current camera mode (photo/video)
    var cameraMode: CameraMode = .photo

    /// Whether video is currently recording
    var isRecording: Bool = false

    /// Current recording duration in seconds
    var recordingDuration: TimeInterval = 0

    /// Video stabilization mode
    var videoStabilizationMode: VideoStabilizationMode = .standard

    /// Whether torch (flashlight) is enabled for video
    var isTorchEnabled: Bool = false

    /// Pending camera mode to restore after force reset
    var pendingModeRestore: CameraMode?

    /// Preview layer (for UI use)
    nonisolated(unsafe) let previewLayer: AVCaptureVideoPreviewLayer

    /// Photo stream (contains photo and location info)
    let photoStream: AsyncStream<(photo: AVCapturePhoto, location: CLLocation?)>

    /// Deferred photo stream (Deferred Photo Processing - for background computational photography)
    let deferredPhotoStream: AsyncStream<(proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?)>

    /// Video stream (emitted when recording finishes, contains video URL and location)
    let videoStream: AsyncStream<(url: URL, location: CLLocation?)>

    // MARK: - Focus State

    /// Whether focus is adjusting
    var isAdjustingFocus = false

    // MARK: - Module Managers

    /// Portrait mode service
    let portraitManager = PortraitModeService()

    /// Macro mode service
    let macroManager = MacroModeService()

    /// Zoom manager
    var zoomManager: ZoomManager?


    /// Flash manager
    let flashManager = FlashManager()

    /// Macro switching manager
    let macroSwitchingManager = MacroSwitchingManager()

    /// Camera switching manager
    let cameraSwitchingManager = CameraSwitchingManager()

    // MARK: - Public Module Properties

    /// Current capture mode (stored property, synced with portraitManager)
    private(set) var captureMode: CaptureMode = .photo

    /// Manually set Portrait mode (disabling includes cooldown to prevent immediate re-enable)
    func setPortraitMode(enabled: Bool) {
        if enabled {
            portraitManager.captureMode = .portrait
        } else {
            // Use manual disable method, which triggers cooldown
            portraitManager.manuallyDisablePortraitMode()
        }
    }

    /// Whether Portrait conditions are stably met (for UI button display)
    var isPortraitConditionStable: Bool {
        portraitManager.isPortraitConditionStable
    }

    /// Current zoom factor (stored property, ensures reactive UI updates)
    var currentZoomFactor: CGFloat = 1.0

    /// Minimum zoom factor
    var minZoomFactor: CGFloat {
        zoomManager?.minZoomFactor ?? 1.0
    }

    /// Maximum zoom factor
    var maxZoomFactor: CGFloat {
        zoomManager?.maxZoomFactor ?? 1.0
    }

    /// Available preset zoom factors
    var availablePresetZooms: [CGFloat] {
        zoomManager?.availablePresetZooms ?? []
    }

    /// Whether current camera is front-facing (stored property, ensures reactive UI updates)
    var isFrontCamera: Bool = false

    /// Whether auto macro switching is enabled (user setting)
    var isAutoMacroEnabled: Bool {
        get { macroManager.isAutoMacroEnabled }
        set { macroManager.isAutoMacroEnabled = newValue }
    }

    /// Whether currently in macro mode
    var isMacroModeActive: Bool {
        macroManager.isMacroModeActive
    }

    /// Whether currently in close-up focus range (for showing macro indicator)
    var isInMacroFocusRange: Bool {
        macroManager.isInMacroFocusRange
    }

    /// Whether Macro mode is suggested (for showing toast and button)
    var isMacroSuggested: Bool {
        macroManager.isMacroSuggested
    }


    /// Current flash mode (synced with FlashManager for persistence)
    var flashMode: FlashMode {
        didSet {
            flashManager.setFlashMode(flashMode)
        }
    }

    /// Whether flash is available
    var isFlashAvailable: Bool {
        guard let device = deviceInput?.device else { return false }
        return flashManager.isFlashAvailable(on: device)
    }

    /// Current aspect ratio (for post-capture cropping)
    var selectedAspectRatio: AspectRatio = .ratio4_3

    // MARK: - Live Photo

    /// Whether Live Photo is enabled
    private(set) var isLivePhotoEnabled: Bool = false

    /// Live Photo manager (actor for thread-safe capture coordination)
    let livePhotoManager = LivePhotoManager()

    /// Set Live Photo enabled state
    func setLivePhotoEnabled(_ enabled: Bool) {
        isLivePhotoEnabled = enabled

        if enabled {
            // Live Photo and Portrait are mutually exclusive
            if captureMode == .portrait {
                setPortraitMode(enabled: false)
            }

            // Live Photo and Deferred Photo Processing are mutually exclusive
            // Deferred processing intercepts the photo callback, breaking Live Photo pairing
            sessionQueue.async { [weak self] in
                guard let self = self, let photoOutput = self.photoOutput else { return }
                if photoOutput.isAutoDeferredPhotoDeliveryEnabled {
                    photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
                    self.logger.info("Disabled Deferred Photo Delivery for Live Photo compatibility")
                }
            }

            logger.info("Live Photo enabled")
        } else {
            // Clean up any pending captures
            Task {
                await livePhotoManager.cleanup()
            }

            // Re-enable Deferred Photo Processing when Live Photo is disabled
            sessionQueue.async { [weak self] in
                guard let self = self, let photoOutput = self.photoOutput else { return }
                if photoOutput.isAutoDeferredPhotoDeliverySupported && !photoOutput.isAutoDeferredPhotoDeliveryEnabled {
                    photoOutput.isAutoDeferredPhotoDeliveryEnabled = true
                    self.logger.info("Re-enabled Deferred Photo Delivery")
                }
            }

            logger.info("Live Photo disabled")
        }
    }

    // MARK: - Internal State
    //
    // Most of this is internal rather than private only so the extensions in
    // the CameraManager+ files can reach it. Treat it as private to the camera.

    // Configuration
    let config = CameraConfiguration.shared

    /// Session state container (dedicated for sessionQueue use, avoiding nonisolated on stored properties)
    final class SessionController: @unchecked Sendable {
        let captureSession = AVCaptureSession()
        var deviceInput: AVCaptureDeviceInput?
        var photoOutput: AVCapturePhotoOutput?
        var videoOutput: AVCaptureVideoDataOutput?
        var movieOutput: AVCaptureMovieFileOutput?  // For video recording
        var audioInput: AVCaptureDeviceInput?       // For audio during video recording
        var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        var isSessionConfigured = false
    }

    let sessionController = SessionController()
    let sessionQueue: DispatchQueue
    let sessionQueueKey = DispatchSpecificKey<Bool>()  // For detecting if on sessionQueue
    let videoOutputQueue: DispatchQueue  // Dedicated video output queue

    // Session-related computed properties (nonisolated access to sessionQueue, centralized shared state management)
    var captureSession: AVCaptureSession { sessionController.captureSession }
    var deviceInput: AVCaptureDeviceInput? {
        get { sessionController.deviceInput }
        set { sessionController.deviceInput = newValue }
    }
    var photoOutput: AVCapturePhotoOutput? {
        get { sessionController.photoOutput }
        set { sessionController.photoOutput = newValue }
    }
    var videoOutput: AVCaptureVideoDataOutput? {
        get { sessionController.videoOutput }
        set { sessionController.videoOutput = newValue }
    }
    var rotationCoordinator: AVCaptureDevice.RotationCoordinator? {
        get { sessionController.rotationCoordinator }
        set { sessionController.rotationCoordinator = newValue }
    }
    var movieOutput: AVCaptureMovieFileOutput? {
        get { sessionController.movieOutput }
        set { sessionController.movieOutput = newValue }
    }
    var audioInput: AVCaptureDeviceInput? {
        get { sessionController.audioInput }
        set { sessionController.audioInput = newValue }
    }
    var isSessionConfigured: Bool {
        get { sessionController.isSessionConfigured }
        set { sessionController.isSessionConfigured = newValue }
    }

    // Video recording state
    var recordingTimer: Timer?
    var recordingStartTime: Date?

    // Control modules
    let focusControl = FocusControl()

    // Manual focus cooldown - prevents subjectAreaDidChange from immediately resetting manual focus
    var lastManualFocusTime: Date?
    let manualFocusCooldown: TimeInterval = 5.0  // 5 seconds cooldown

    // Subject detector (exposed so the view can receive its detections)
    let subjectDetector = SubjectDetector()

    // Subject lock service (for continuous tracking and focus)
    let subjectLockService = SubjectLockService()

    // Continuous focus controller (for subject lock)
    private let continuousFocusController = ContinuousFocusController()


    // KVO observers
    var focusObservation: NSKeyValueObservation?
    var lensPositionObservation: NSKeyValueObservation?

    // Session observer registration flag (prevent duplicate registration)
    var sessionObserversSetup = false

    // Ultra-wide device (for macro mode)
    var ultraWideDevice: AVCaptureDevice?

    // Location manager (for adding location info to photos)
    let locationManager = LocationManager()

    // The write ends of the three public streams
    let photoContinuation: AsyncStream<(photo: AVCapturePhoto, location: CLLocation?)>.Continuation
    let deferredPhotoContinuation: AsyncStream<(proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?)>.Continuation
    let videoContinuation: AsyncStream<(url: URL, location: CLLocation?)>.Continuation

    // Capture state
    // Note: No lock needed - CameraManager is @MainActor isolated,
    // all access is guaranteed to be on the main thread
    var isCapturingPhoto = false
    var pendingStopAfterCapture = false
    var captureBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Logger
    let logger = Logger(subsystem: Log.subsystem, category: "CameraManager")

    // MARK: - Macro Check Timer (replaces per-frame check)
    var macroCheckTimer: Timer?

    /// Current lensPosition (for per-frame macro condition detection)
    var currentLensPosition: Float = 1.0

    // MARK: - Initialization

    override init() {
        // Create preview layer
        self.previewLayer = AVCaptureVideoPreviewLayer()
        self.previewLayer.videoGravity = .resizeAspectFill

        // Create session queue (for session configuration)
        self.sessionQueue = DispatchQueue(label: "\(Log.subsystem).camera.session")
        self.sessionQueue.setSpecific(key: sessionQueueKey, value: true)

        // Use main queue as video output queue
        // This avoids actor isolation issues since CameraManager and SubjectDetector are both @MainActor
        self.videoOutputQueue = DispatchQueue.main

        // Initialize zoom manager
        self.zoomManager = ZoomManager(sessionQueue: sessionQueue)

        // Load persisted flash mode from FlashManager
        self.flashMode = flashManager.currentMode

        (photoStream, photoContinuation) = AsyncStream.makeStream()
        (deferredPhotoStream, deferredPhotoContinuation) = AsyncStream.makeStream()
        (videoStream, videoContinuation) = AsyncStream.makeStream()

        super.init()

        // Set up Portrait Manager dependency injection
        portraitManager.checkDepthCapability = { [weak self] in
            self?.checkDepthCapability() ?? false
        }

        // Sync captureMode changes to CameraManager (triggers @Observable update)
        portraitManager.onCaptureModeChanged = { [weak self] newMode in
            self?.captureMode = newMode
        }

        // Connect preview layer to session
        self.previewLayer.session = captureSession

        // Request location permission
        locationManager.requestAuthorization()

        // Set up auto-focus callback (triggered by subject detection)
        subjectDetector.onAutoFocus = { [weak self] normalizedPoint in
            guard let self = self else { return }

            Task { @MainActor in
                // normalizedPoint is normalized coordinates (0-1 range)
                // Pass directly to focusControl, which expects normalized coordinates
                guard let device = self.sessionController.deviceInput?.device else {
                    self.logger.error("No device available for auto-focus")
                    return
                }

                // Execute focus on background queue
                self.sessionQueue.async { [weak self] in
                    self?.focusControl.focus(at: normalizedPoint, on: device)
                }
            }
        }

        // Set up Portrait conditions update callback (receives subject detections + salient object)
        subjectDetector.onPortraitConditionsUpdate = { [weak self] subjectDetections, salientObject in
            guard let self = self else { return }
            Task { @MainActor in
                let uiZoom = (self.zoomManager?.currentZoomFactor ?? 1.0) / 2.0
                self.portraitManager.updateConditions(
                    subjectDetections: subjectDetections,
                    salientObject: salientObject,
                    currentZoom: uiZoom
                )
            }
        }

        // Set up subject lock focus callback
        setupSubjectLockCallbacks()

        // Monitor Session interruptions and errors (critical fix)
        setupSessionObservers()
    }

    /// Set up subject lock service callbacks
    private func setupSubjectLockCallbacks() {
        // Update focus when subject lock requests it
        subjectLockService.onFocusPointUpdate = { [weak self] focusPoint in
            guard let self = self else { return }

            Task { @MainActor in
                guard let device = self.sessionController.deviceInput?.device else { return }

                // Use continuous focus controller for smooth tracking
                self.sessionQueue.async { [weak self] in
                    self?.continuousFocusController.updateFocusPoint(focusPoint, on: device)
                }
            }
        }
    }

    @MainActor
    deinit {
        // Clean up all resources
        recordingTimer?.invalidate()
        recordingTimer = nil
        focusObservation?.invalidate()
        lensPositionObservation?.invalidate()
        NotificationCenter.default.removeObserver(self)

        // Finish async stream continuations
        photoContinuation.finish()
        deferredPhotoContinuation.finish()
        videoContinuation.finish()
    }
}
