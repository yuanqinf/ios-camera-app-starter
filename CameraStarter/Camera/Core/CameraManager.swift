//
//  CameraManager.swift
//  CameraStarter
//
//  Core camera manager
//  Phase 1: Basic features - preview, capture, camera switching
//

@preconcurrency import AVFoundation
import os.log
import UIKit
import CoreLocation
import VideoToolbox

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
    private(set) var state: CameraState = .initializing

    /// Current camera (front/back)
    private(set) var currentDevice: CameraDevice = .back

    /// Whether camera is running
    private(set) var isRunning = false

    /// Whether camera is currently starting (to prevent concurrent start calls)
    private var isStarting = false

    /// Latest pixel buffer from video data output (for frame capture)
    var _latestPixelBuffer: CVPixelBuffer?

    // MARK: - Video Recording Properties

    /// Current camera mode (photo/video)
    private(set) var cameraMode: CameraMode = .photo

    /// Whether video is currently recording
    private(set) var isRecording: Bool = false

    /// Current recording duration in seconds
    private(set) var recordingDuration: TimeInterval = 0

    /// Video stabilization mode
    var videoStabilizationMode: VideoStabilizationMode = .standard

    /// Whether torch (flashlight) is enabled for video
    private(set) var isTorchEnabled: Bool = false

    /// Pending camera mode to restore after force reset
    private var pendingModeRestore: CameraMode?

    /// Whether action mode is supported on current device
    var isActionModeSupported: Bool {
        guard let device = deviceInput?.device else { return false }
        return device.activeFormat.isVideoStabilizationModeSupported(.cinematicExtendedEnhanced)
    }

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
    private(set) var isAdjustingFocus = false

    // MARK: - Module Managers

    /// Portrait mode service
    private let portraitManager = PortraitModeService()

    /// Macro mode service
    private let macroManager = MacroModeService()

    /// Zoom manager
    private var zoomManager: ZoomManager?


    /// Flash manager
    private let flashManager = FlashManager()

    /// Macro switching manager
    private let macroSwitchingManager = MacroSwitchingManager()

    /// Camera switching manager
    private let cameraSwitchingManager = CameraSwitchingManager()

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
    private(set) var currentZoomFactor: CGFloat = 1.0

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
    private(set) var isFrontCamera: Bool = false

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
    private(set) var flashMode: FlashMode {
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

            // ⚠️ Live Photo and Deferred Photo Processing are mutually exclusive
            // Deferred processing intercepts the photo callback, breaking Live Photo pairing
            sessionQueue.async { [weak self] in
                guard let self = self, let photoOutput = self.photoOutput else { return }
                if photoOutput.isAutoDeferredPhotoDeliveryEnabled {
                    photoOutput.isAutoDeferredPhotoDeliveryEnabled = false
                    self.logger.info("📸 Disabled Deferred Photo Delivery for Live Photo compatibility")
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
                    self.logger.info("📸 Re-enabled Deferred Photo Delivery")
                }
            }

            logger.info("Live Photo disabled")
        }
    }

    // MARK: - Private Properties

    // Configuration
    private let config = CameraConfiguration.shared

    /// Session state container (dedicated for sessionQueue use, avoiding nonisolated on stored properties)
    private final class SessionController: @unchecked Sendable {
        let captureSession = AVCaptureSession()
        var deviceInput: AVCaptureDeviceInput?
        var photoOutput: AVCapturePhotoOutput?
        var videoOutput: AVCaptureVideoDataOutput?
        var movieOutput: AVCaptureMovieFileOutput?  // For video recording
        var audioInput: AVCaptureDeviceInput?       // For audio during video recording
        var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        var isSessionConfigured = false
    }

    private let sessionController = SessionController()
    private let sessionQueue: DispatchQueue
    private let sessionQueueKey = DispatchSpecificKey<Bool>()  // For detecting if on sessionQueue
    private let videoOutputQueue: DispatchQueue  // 🔧 Dedicated video output queue

    // Session-related computed properties (nonisolated access to sessionQueue, centralized shared state management)
    private var captureSession: AVCaptureSession { sessionController.captureSession }
    private var deviceInput: AVCaptureDeviceInput? {
        get { sessionController.deviceInput }
        set { sessionController.deviceInput = newValue }
    }
    private var photoOutput: AVCapturePhotoOutput? {
        get { sessionController.photoOutput }
        set { sessionController.photoOutput = newValue }
    }
    private var videoOutput: AVCaptureVideoDataOutput? {
        get { sessionController.videoOutput }
        set { sessionController.videoOutput = newValue }
    }
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator? {
        get { sessionController.rotationCoordinator }
        set { sessionController.rotationCoordinator = newValue }
    }
    private var movieOutput: AVCaptureMovieFileOutput? {
        get { sessionController.movieOutput }
        set { sessionController.movieOutput = newValue }
    }
    private var audioInput: AVCaptureDeviceInput? {
        get { sessionController.audioInput }
        set { sessionController.audioInput = newValue }
    }
    private var isSessionConfigured: Bool {
        get { sessionController.isSessionConfigured }
        set { sessionController.isSessionConfigured = newValue }
    }

    // Video recording state
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

    // Control modules
    private let focusControl = FocusControl()

    // Manual focus cooldown - prevents subjectAreaDidChange from immediately resetting manual focus
    private var lastManualFocusTime: Date?
    private let manualFocusCooldown: TimeInterval = 5.0  // 5 seconds cooldown

    // Subject detector (exposed so the view can receive its detections)
    let subjectDetector = SubjectDetector()

    // Subject lock service (for continuous tracking and focus)
    let subjectLockService = SubjectLockService()

    // Continuous focus controller (for subject lock)
    private let continuousFocusController = ContinuousFocusController()


    // KVO observers
    private var focusObservation: NSKeyValueObservation?
    private var lensPositionObservation: NSKeyValueObservation?

    // Session observer registration flag (prevent duplicate registration)
    private var sessionObserversSetup = false

    // Ultra-wide device (for macro mode)
    private var ultraWideDevice: AVCaptureDevice?

    // Location manager (for adding location info to photos)
    private let locationManager = LocationManager()

    // Photo stream continuation (nonisolated access)
    private var addToPhotoStream: (((photo: AVCapturePhoto, location: CLLocation?)) -> Void)?
    private var photoContinuation: AsyncStream<(photo: AVCapturePhoto, location: CLLocation?)>.Continuation?

    // Deferred photo stream (Deferred Photo Processing)
    private var addToDeferredPhotoStream: (((proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?)) -> Void)?
    private var deferredPhotoContinuation: AsyncStream<(proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?)>.Continuation?

    // Video stream (for video recording completion)
    private var addToVideoStream: (((url: URL, location: CLLocation?)) -> Void)?
    private var videoContinuation: AsyncStream<(url: URL, location: CLLocation?)>.Continuation?

    // Capture state
    // Note: No lock needed - CameraManager is @MainActor isolated,
    // all access is guaranteed to be on the main thread
    private var isCapturingPhoto = false
    private var pendingStopAfterCapture = false
    private var captureBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Logger
    private let logger = Logger(subsystem: Log.subsystem, category: "CameraManager")

    // MARK: - Macro Check Timer (replaces per-frame check)
    private var macroCheckTimer: Timer?

    // MARK: - Initialization

    override init() {
        // Create preview layer
        self.previewLayer = AVCaptureVideoPreviewLayer()
        self.previewLayer.videoGravity = .resizeAspectFill

        // Create session queue (for session configuration)
        self.sessionQueue = DispatchQueue(label: "\(Log.subsystem).camera.session")
        self.sessionQueue.setSpecific(key: sessionQueueKey, value: true)

        // 🔧 Use main queue as video output queue
        // This avoids actor isolation issues since CameraManager and SubjectDetector are both @MainActor
        self.videoOutputQueue = DispatchQueue.main

        // Initialize zoom manager
        self.zoomManager = ZoomManager(sessionQueue: sessionQueue)

        // Load persisted flash mode from FlashManager
        self.flashMode = flashManager.currentMode

        // Initialize photo stream
        var tempContinuation: AsyncStream<(photo: AVCapturePhoto, location: CLLocation?)>.Continuation?
        self.photoStream = AsyncStream { continuation in
            tempContinuation = continuation
        }

        // Initialize deferred photo stream (Deferred Photo Processing)
        var tempDeferredContinuation: AsyncStream<(proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?)>.Continuation?
        self.deferredPhotoStream = AsyncStream { continuation in
            tempDeferredContinuation = continuation
        }

        // Initialize video stream
        var tempVideoContinuation: AsyncStream<(url: URL, location: CLLocation?)>.Continuation?
        self.videoStream = AsyncStream { continuation in
            tempVideoContinuation = continuation
        }

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

        // 🔧 Store continuation first, then set up photo stream closure
        self.photoContinuation = tempContinuation
        self.addToPhotoStream = { [weak self] tuple in
            self?.photoContinuation?.yield(tuple)
        }

        // Set up deferred photo stream closure
        self.deferredPhotoContinuation = tempDeferredContinuation
        self.addToDeferredPhotoStream = { [weak self] tuple in
            self?.deferredPhotoContinuation?.yield(tuple)
        }

        // Set up video stream closure
        self.videoContinuation = tempVideoContinuation
        self.addToVideoStream = { [weak self] tuple in
            self?.videoContinuation?.yield(tuple)
        }

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

        // 🔧 Monitor Session interruptions and errors (critical fix)
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
        photoContinuation?.finish()
        deferredPhotoContinuation?.finish()
        videoContinuation?.finish()
    }

    // MARK: - Session Monitoring

    /// Set up Session interruption and error monitoring
    private func setupSessionObservers() {
        // Prevent duplicate observer registration
        guard !sessionObserversSetup else { return }

        // Monitor session interruptions (calls, FaceTime, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: captureSession
        )

        // Monitor session interruption end
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: captureSession
        )

        // Monitor session runtime errors
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: captureSession
        )

        // Monitor subject area changes (subject moved, trigger refocus)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(subjectAreaDidChange),
            name: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: nil  // Listen to all devices
        )

        sessionObserversSetup = true
    }

    @objc private func sessionWasInterrupted(notification: NSNotification) {
        guard let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
              let reasonIntegerValue = AVCaptureSession.InterruptionReason(rawValue: userInfoValue) else {
            logger.warning("⚠️ Session was interrupted (unknown reason)")
            return
        }

        logger.warning("⚠️ Session was interrupted: reason=\(userInfoValue)")

        Task { @MainActor in
            switch reasonIntegerValue {
            case .videoDeviceNotAvailableInBackground:
                self.logger.info("Camera unavailable in background")
            case .audioDeviceInUseByAnotherClient:
                self.logger.info("Audio device in use by another app")
            case .videoDeviceInUseByAnotherClient:
                self.logger.warning("⚠️ Camera in use by another app - session stopped")
            case .videoDeviceNotAvailableWithMultipleForegroundApps:
                self.logger.warning("⚠️ Camera unavailable with multiple apps")
            case .videoDeviceNotAvailableDueToSystemPressure:
                self.logger.error("❌ Camera unavailable due to system pressure")
            default:
                self.logger.warning("⚠️ Session interrupted: unknown reason")
            }
        }
    }

    @objc private func sessionInterruptionEnded(notification: NSNotification) {
        logger.info("✅ Session interruption ended - camera available again")

        // After interruption ends, session should auto-recover
        // But we need to verify video output connection is still valid
        Task { @MainActor in
            // Wait briefly for session to stabilize
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

            // Verify session is actually running
            if !self.captureSession.isRunning {
                logger.warning("⚠️ Session not running after interruption - attempting restart")
                try? await self.start()
            }

            // 🔧 Ensure depth data settings weren't reset by system
            self.ensureDepthDataEnabled()
        }
    }

    @objc private func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
            logger.error("❌ Session runtime error (unknown)")
            return
        }

        logger.error("❌ Session runtime error: \(error.localizedDescription)")

        // Decide whether to attempt recovery based on error type
        Task { @MainActor in
            if error.code == .mediaServicesWereReset {
                logger.info("🔄 Media services reset - attempting to restart session")

                // Media services reset, need to reconfigure session
                self.isSessionConfigured = false

                do {
                    try await self.start()
                    logger.info("✅ Session restarted successfully after media services reset")
                } catch {
                    logger.error("❌ Failed to restart session: \(error.localizedDescription)")
                }
            } else if error.code == .deviceAlreadyUsedByAnotherSession {
                logger.error("❌ Device already in use by another session")
            } else {
                logger.error("❌ Unhandled session error: \(error.code.rawValue)")
            }
        }
    }

    @objc private func subjectAreaDidChange(notification: NSNotification) {
        // Check if we're in manual focus cooldown period
        // This prevents the system from immediately resetting manual focus
        if let lastFocus = lastManualFocusTime {
            let elapsed = Date().timeIntervalSince(lastFocus)
            if elapsed < manualFocusCooldown {
                // Still in cooldown - don't reset focus
                return
            }
        }

        // Subject moved significantly - trigger refocus for responsive subject tracking
        sessionQueue.async { [weak self] in
            guard let self = self,
                  let device = self.deviceInput?.device,
                  device.isFocusModeSupported(.continuousAutoFocus) else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                // Reset to continuous autofocus (will refocus on new subject position)
                device.focusMode = .continuousAutoFocus

                // Also reset exposure to continuous auto for proper metering on moved subject
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }

            } catch {
                self.logger.error("Failed to refocus after subject change: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lifecycle

    /// Force reset camera session to clean state
    /// Call this when camera is in an inconsistent state that prevents normal operation
    private func forceResetSession() {
        logger.warning("🔄 Force resetting camera session...")

        // 🔧 Preserve current camera mode - will be restored after reset
        let previousMode = cameraMode

        // Clear all internal state flags first
        isRunning = false
        isSessionConfigured = false
        pendingStopAfterCapture = false

        // Reset mode states (but preserve cameraMode for later restoration)
        cameraMode = .photo  // Temporarily set to photo for clean restart
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        // Store previous mode for restoration after session restart
        // Will be used by start() to switch back if needed
        self.pendingModeRestore = previousMode != .photo ? previousMode : nil

        // 🔧 All session operations MUST be on sessionQueue to avoid race conditions
        // Using DispatchQueue.sync to block until complete, but checking if we're already on the queue
        let resetBlock = { [weak self] in
            guard let self = self else { return }

            // Stop session if running
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }

            self.captureSession.beginConfiguration()
            defer { self.captureSession.commitConfiguration() }

            // Remove all inputs
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }

            // Remove ALL outputs (including photo output - will be recreated)
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }
        }

        // Check if we're already on sessionQueue to avoid deadlock
        if DispatchQueue.getSpecific(key: sessionQueueKey) != nil {
            resetBlock()
        } else {
            sessionQueue.sync(execute: resetBlock)
        }

        // Clear ALL references (will be recreated in configureSession)
        deviceInput = nil
        audioInput = nil
        movieOutput = nil
        photoOutput = nil
        videoOutput = nil

        logger.info("✅ Camera session force reset complete")
    }

    /// Start camera
    func start() async throws {
        // 🔧 Prevent concurrent start calls (e.g., from both onAppear and onChange)
        guard !isStarting else {
            logger.info("⏳ Camera start already in progress, skipping duplicate call")
            return
        }

        // 🔧 Verify actual session state, not just isRunning flag
        // This handles race condition when user quickly backgrounds then foregrounds app
        let actuallyRunning = captureSession.isRunning

        if isRunning && actuallyRunning {
            // 🔧 Clear pending stop flag if start is called while already running
            // This handles the race condition: user backgrounds app during capture,
            // then foregrounds before capture completes
            if pendingStopAfterCapture {
                pendingStopAfterCapture = false
                logger.info("✅ Cleared pending stop - camera will stay running")
            }
            return
        }

        // Mark as starting to prevent concurrent calls
        isStarting = true
        defer { isStarting = false }

        // 🔧 If isRunning flag is true but session is not actually running,
        // force reset to clean state and proceed with full restart
        if isRunning && !actuallyRunning {
            logger.warning("⚠️ isRunning=true but session stopped - forcing full reset")
            forceResetSession()
        }

        // 🔧 If session is still running but isRunning is false (race condition from stop()),
        // wait briefly for session to stop, then force reset if still running
        if !isRunning && actuallyRunning {
            logger.warning("⚠️ Session still running but isRunning=false - waiting for stop...")
            // Wait briefly for the async stop to complete
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            if captureSession.isRunning {
                logger.warning("⚠️ Session still running after wait - forcing reset")
                forceResetSession()
            }
        }

        // 🔧 If session is stuck in unknown state, force reset
        if !isRunning && isSessionConfigured && !captureSession.isRunning {
            // Session was configured but not running - might be in bad state
            logger.warning("⚠️ Session configured but not running - forcing reset")
            forceResetSession()
        }

        // 🔧 If in video mode but not running, force reset to photo mode
        // This handles the case when app was backgrounded in video mode
        if cameraMode == .video && !captureSession.isRunning {
            logger.warning("⚠️ In video mode but session not running - forcing reset to photo mode")
            forceResetSession()
        }

        // 🔧 If photo output is missing (e.g., removed for video mode), force reset
        // This ensures we always have a valid photo output after restart
        if isSessionConfigured && photoOutput == nil {
            logger.warning("⚠️ Photo output is nil - forcing reset")
            forceResetSession()
        }

        // Check permissions
        state = .checkingPermissions
        try await checkAuthorization()

        // Configure session
        if !isSessionConfigured {
            state = .configuring
            try await configureSession()
            isSessionConfigured = true
        }

        // Start session
        state = .ready
        await startSession()
        state = .running
        isRunning = true

        // 🔧 Ensure depth data settings are enabled (prevent reset after configuration)
        ensureDepthDataEnabled()

        // 🔧 Reset macro state (clear previous manual disable flags, etc.)
        await MainActor.run {
            macroManager.resetState()
        }

        // 🔧 Restart lens position observation (needs re-listening after app restart)
        if let device = sessionController.deviceInput?.device {
            await MainActor.run {
                startLensPositionObservation(for: device)
                startFocusObservation(for: device)
            }
        }

        // 🔧 Re-set videoOutput delegate (removed in stop(), needs restoration after restart)
        if let videoOutput = videoOutput {
            sessionQueue.async { [weak self] in
                guard let self = self else { return }
                if videoOutput.sampleBufferDelegate == nil {
                    Task { @MainActor in
                        videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)
                    }
                }
            }
        }

        // 📍 Ensure location updates are running for photo geotagging
        locationManager.resumeLocationUpdates()

        // Start macro condition timer (4x/sec instead of per-frame)
        macroCheckTimer?.invalidate()
        macroCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRunning else { return }
                self.checkMacroConditionPerFrame(lensPosition: self.currentLensPosition)
            }
        }

        // 🔧 Restore camera mode if there was a pending restore after force reset
        if let modeToRestore = pendingModeRestore {
            pendingModeRestore = nil
            logger.info("🔄 Restoring camera mode to \(modeToRestore.rawValue) after reset")
            setCameraMode(modeToRestore)
        }
    }

    // MARK: - Capture Lifecycle Management

    @MainActor
    private func beginCaptureLifecycle() {
        pendingStopAfterCapture = false
        isCapturingPhoto = true

        if captureBackgroundTask == .invalid {
            captureBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PhotoCapture") { [weak self] in
                self?.logger.warning("⚠️ Background task expired during capture")
                self?.endCaptureBackgroundTask()
            }
        }
    }

    @MainActor
    private func finishCaptureLifecycle() {
        isCapturingPhoto = false
        endCaptureBackgroundTask()

        if pendingStopAfterCapture {
            pendingStopAfterCapture = false
            stop(immediately: true)
        }
    }

    @MainActor
    private func endCaptureBackgroundTask() {
        guard captureBackgroundTask != .invalid else { return }

        // 🔧 Save task ID first and immediately set to invalid to prevent race condition
        let taskToEnd = captureBackgroundTask
        captureBackgroundTask = .invalid

        // Then end the task
        UIApplication.shared.endBackgroundTask(taskToEnd)
    }

    /// Stop camera
    func stop(immediately: Bool = false) {
        if !immediately && isCapturingPhoto {
            pendingStopAfterCapture = true
            logger.info("⏳ Stop requested during capture – will stop after capture finishes")
            return
        }

        guard isRunning else { return }

        // Stop macro check timer
        macroCheckTimer?.invalidate()
        macroCheckTimer = nil

        // Reset tracking state (stop expensive Vision trackers)
        subjectDetector.resetTracking()

        // Stop focus observation first
        stopFocusObservation()
        stopLensPositionObservation()

        // Update state immediately
        isRunning = false
        state = .ready

        // 🔧 Stop session on sessionQueue - use async to avoid blocking UI
        // The session will stop asynchronously, but state flags are already updated
        // start() will detect and handle any state inconsistency via forceResetSession()
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Remove videoOutput delegate to prevent retain cycles
            if let videoOutput = self.videoOutput {
                videoOutput.setSampleBufferDelegate(nil, queue: nil)
            }

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    // MARK: - Flash Control

    /// Toggle flash mode (auto -> off -> on -> auto)
    func toggleFlashMode() {
        switch flashMode {
        case .auto:
            flashMode = .off
        case .off:
            flashMode = .on
        case .on:
            flashMode = .auto
        }
    }

    // MARK: - Photo Capture

    /// Take photo
    func takePhoto() {
        // Only allow photo capture in photo mode
        guard cameraMode == .photo else {
            logger.warning("⚠️ takePhoto called in video mode, ignoring (cameraMode=\(self.cameraMode.rawValue))")
            return
        }

        // Check if camera is running
        guard isRunning else {
            logger.error("Camera is not running")
            return
        }

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        // 🔧 Read all needed state on main thread (avoid cross-thread access later)
        let isPortraitMode = (captureMode == .portrait)
        let isMacro = self.isMacroModeActive

        // Record capture start (begin background task to avoid early suspension)
        Task { @MainActor in
            self.beginCaptureLifecycle()
        }

        // Zero shutter lag: iOS Responsive Capture uses buffered frames
        // Capture immediately - NO focus/exposure locking needed
        // iOS handles this automatically with ZSL buffer when isResponsiveCaptureEnabled = true
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            guard let photoOutput = self.photoOutput else {
                self.logger.error("Photo output not available")
                Task { @MainActor in
                    self.finishCaptureLifecycle()
                }
                return
            }

            // Create photo settings with minimal configuration for speed
            var photoSettings = AVCapturePhotoSettings()

            // Use HEVC encoding (if supported)
            if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                photoSettings = AVCapturePhotoSettings(
                    format: [AVVideoCodecKey: AVVideoCodecType.hevc]
                )
            }

            // Set max resolution (match native camera)
            photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions

            // Use .quality for best computational photography results (Deep Fusion, Smart HDR)
            photoSettings.photoQualityPrioritization = .quality

            // Auto-enable computational photography features
            photoSettings.isAutoRedEyeReductionEnabled = true

            // Note: Content-Aware Distortion Correction is pre-enabled at camera startup
            // to avoid ~300ms first-capture delay. No need to set it here.

            // 💡 Configure flash mode
            if self.isFrontCamera {
                photoSettings.flashMode = .off
            } else if self.flashManager.isFlashModeSupported(self.flashMode, on: photoOutput) {
                photoSettings.flashMode = self.flashMode.systemFlashMode
            } else {
                photoSettings.flashMode = .off
            }

            // Configure depth data capture (Portrait mode)
            if isPortraitMode {
                if isMacro {
                    photoSettings.isDepthDataDeliveryEnabled = false
                } else if photoOutput.isDepthDataDeliveryEnabled {
                    photoSettings.isDepthDataDeliveryEnabled = true
                    photoSettings.embedsDepthDataInPhoto = true
                    if photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                        photoSettings.isPortraitEffectsMatteDeliveryEnabled = true
                        photoSettings.embedsPortraitEffectsMatteInPhoto = true
                    }
                    let availableMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
                    if !availableMatteTypes.isEmpty {
                        photoSettings.enabledSemanticSegmentationMatteTypes = availableMatteTypes
                    }
                } else {
                    photoSettings.isDepthDataDeliveryEnabled = false
                }
            } else {
                photoSettings.isDepthDataDeliveryEnabled = false
            }

            // Configure Live Photo capture
            if self.isLivePhotoEnabled && photoOutput.isLivePhotoCaptureEnabled {
                let movieURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                photoSettings.livePhotoMovieFileURL = movieURL

                // Register capture in LivePhotoManager BEFORE triggering capturePhoto
                // to avoid race condition where delegate callbacks arrive before registration
                let photoID = photoSettings.uniqueID
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    let started = await self.livePhotoManager.startCapture(id: photoID, movieURL: movieURL)
                    if !started {
                        self.logger.warning("Failed to start Live Photo capture - limit reached")
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            }

            // Apply rotation
            if let rotationCoordinator = self.rotationCoordinator,
               let photoOutputConnection = photoOutput.connection(with: .video) {
                let rotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
                photoOutputConnection.videoRotationAngle = rotationAngle
            }

            photoOutput.capturePhoto(with: photoSettings, delegate: self)
        }
    }


    // MARK: - Camera Switching

    /// Switch between front and back cameras
    func switchCamera() {
        // Reset tracking state before switching (trackers are camera-specific)
        subjectDetector.resetTracking()

        cameraSwitchingManager.switchCamera(
            from: currentDevice,
            context: createCameraSwitchContext(),
            macroManager: macroManager,
            portraitManager: portraitManager
        )
    }

    /// Create camera switch context
    private func createCameraSwitchContext() -> CameraSwitchingManager.SwitchContext {
        CameraSwitchingManager.SwitchContext(
            captureSession: captureSession,
            currentInput: deviceInput,
            sessionQueue: sessionQueue,
            previewLayer: previewLayer,
            updateDeviceInput: { [weak self] input in
                self?.deviceInput = input
            },
            updateRotationCoordinator: { [weak self] device in
                guard let self = self else { return }
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: self.previewLayer
                )
            },
            restartFocusObservation: { [weak self] device in
                self?.startFocusObservation(for: device)
            },
            updateZoomCapabilities: { [weak self] device in
                self?.updateZoomCapabilities(for: device)
            },
            updateZoom: { [weak self] zoom in
                self?.zoomManager?.updateCurrentZoom(zoom)
            },
            updateCurrentDevice: { [weak self] device in
                self?.currentDevice = device
            },
            resetSceneDetection: { },
            getCaptureDevice: { [weak self] position in
                self?.getCaptureDevice(for: position)
            }
        )
    }

    // MARK: - Focus Control

    /// Focus at specified point
    /// - Parameter point: Screen coordinate point (needs conversion to device coordinates)
    func focus(at point: CGPoint) {
        guard let device = deviceInput?.device else {
            logger.error("No device available for focus")
            return
        }

        // Convert screen coordinates to device coordinates (0-1 range)
        guard let devicePoint = CoordinateConverter.uiToDevice(point: point, previewLayer: previewLayer) else {
            logger.error("Failed to convert UI point to device coordinates")
            return
        }

        // Record manual focus time to prevent immediate reset by subjectAreaDidChange
        lastManualFocusTime = Date()

        sessionQueue.async { [weak self] in
            self?.focusControl.focus(at: devicePoint, on: device)
        }
    }

    /// Handle tap with subject selection logic
    /// - Parameters:
    ///   - point: Screen coordinate point
    ///   - currentDetections: Current subject detections from SubjectDetector
    ///   - previewBounds: The bounds of the preview area
    /// - Returns: The subject that was selected (if any), or nil if tap was on empty area
    func handleTapWithSubjectSelection(
        at point: CGPoint,
        currentDetections: [SubjectDetectionResult],
        previewBounds: CGRect
    ) -> SubjectDetectionResult? {
        // Convert tap point to normalized coordinates (0-1)
        let normalizedPoint = CGPoint(
            x: point.x / previewBounds.width,
            y: point.y / previewBounds.height
        )

        // Check if tap is inside any subject's bounding box
        for subject in currentDetections {
            // Subject bounding box is in Vision coordinates (origin at bottom-left)
            // Need to flip Y for UI coordinates (origin at top-left)
            let uiBox = CGRect(
                x: subject.boundingBox.origin.x,
                y: 1 - subject.boundingBox.origin.y - subject.boundingBox.height,
                width: subject.boundingBox.width,
                height: subject.boundingBox.height
            )

            if uiBox.contains(normalizedPoint) {
                // Tap is on this subject - lock onto it
                subjectLockService.lockOn(subject: subject)
                logger.info("Manual lock on subject at tap location")
                return subject
            }
        }

        // Tap is on empty area - keep manual focus mode, just focus at that point
        // User can double-tap or use other gesture to return to auto mode
        // Don't unlock - this allows manual focus to work without resetting to auto
        logger.info("Tap on empty area - manual focus (keeping current tracking mode)")
        return nil
    }

    // MARK: - Zoom Control

    /// Set zoom factor
    /// - Parameter factor: Target zoom factor
    func setZoom(_ factor: CGFloat) {
        // If in macro mode and user manually changes zoom, exit macro mode first then set zoom
        if isMacroModeActive {

            sessionQueue.async { [weak self] in
                guard let self = self else { return }

                // 🔑 Check device availability before changing state
                guard let tripleCamera = self.getCaptureDevice(for: .back) else {
                    self.logger.error("❌ Cannot exit macro mode - Triple Camera not available")
                    return
                }

                // ✅ Mark as non-macro after confirming device available
                Task { @MainActor in
                    self.macroManager.setActive(false)
                }

                do {
                    self.captureSession.beginConfiguration()

                    // Remove current input (ultra-wide)
                    if let currentInput = self.deviceInput {
                        self.captureSession.removeInput(currentInput)
                    }

                    // Add Triple Camera
                    let tripleCameraInput = try AVCaptureDeviceInput(device: tripleCamera)
                    if self.captureSession.canAddInput(tripleCameraInput) {
                        self.captureSession.addInput(tripleCameraInput)
                        self.deviceInput = tripleCameraInput

                        // Set target zoom factor
                        try tripleCamera.lockForConfiguration()
                        defer { tripleCamera.unlockForConfiguration() }

                        let clampedZoom = min(max(factor, tripleCamera.minAvailableVideoZoomFactor), tripleCamera.maxAvailableVideoZoomFactor)
                        tripleCamera.videoZoomFactor = clampedZoom

                        if tripleCamera.isFocusModeSupported(.continuousAutoFocus) {
                            tripleCamera.focusMode = .continuousAutoFocus
                        }

                        // Update rotation coordinator
                        self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                            device: tripleCamera,
                            previewLayer: self.previewLayer
                        )

                        Task { @MainActor in
                            self.zoomManager?.updateCurrentZoom(clampedZoom)
                            self.startFocusObservation(for: tripleCamera)
                            self.startLensPositionObservation(for: tripleCamera)
                            self.logger.info("✅ Exited macro mode and set zoom to \(String(format: "%.1f", clampedZoom))x")
                        }
                    } else {
                        throw CameraError.sessionConfigurationFailed
                    }

                    self.captureSession.commitConfiguration()

                } catch {
                    self.captureSession.commitConfiguration()
                    self.logger.error("❌ Failed to exit macro mode: \(error.localizedDescription)")
                }
            }
            return
        }

        guard let device = deviceInput?.device else {
            logger.error("No device available for zoom")
            return
        }

        // Immediately update UI state
        self.currentZoomFactor = factor

        zoomManager?.setZoom(factor, on: device)
    }

    /// Set zoom factor with optional animation
    /// - Parameters:
    ///   - factor: Target zoom factor
    ///   - animated: Whether to animate the zoom transition (for snap-to-preset)
    func setZoom(_ factor: CGFloat, animated: Bool) {
        guard !isMacroModeActive else {
            // For animated zoom, we don't support macro mode exit
            setZoom(factor)
            return
        }

        guard let device = deviceInput?.device else {
            logger.error("No device available for zoom")
            return
        }

        // Immediately update UI state
        self.currentZoomFactor = factor

        zoomManager?.setZoom(factor, on: device, animated: animated)
    }


    /// Update zoom range and available presets (called during device initialization)
    private func updateZoomCapabilities(for device: AVCaptureDevice) {
        let isFront = device.position == .front
        self.isFrontCamera = isFront

        // Sync currentZoomFactor to default value
        let defaultZoom: CGFloat = isFront ? config.zoom.defaultFrontCameraZoom : config.zoom.defaultBackCameraZoom
        self.currentZoomFactor = defaultZoom

        zoomManager?.updateCapabilities(for: device, isFront: isFront)
    }

    // MARK: - Portrait and Macro Mode Control

    /// Manually toggle macro mode (called when tapping macro icon)
    func toggleMacroMode() {
        let shouldActivate = macroManager.toggleManualMode()

        if shouldActivate {
            activateMacroMode()
        } else {
            deactivateMacroMode()
        }
    }

    /// Check if current lens supports depth data
    private func checkDepthCapability() -> Bool {
        // Allow portrait mode in macro mode (uses computed depth)
        if isMacroModeActive {
            return true  // Allow portrait effects in macro mode
        }

        // Main camera (2x) and telephoto (6x) support hardware depth
        // Ultra-wide (1x) doesn't support
        let deviceZoom = currentZoomFactor
        return deviceZoom >= config.portrait.minZoomForHardwareDepth
            && deviceZoom <= config.portrait.maxZoomForHardwareDepth
    }

    // MARK: - Focus Observation

    /// Start observing focus state changes
    private func startFocusObservation(for device: AVCaptureDevice) {
        // Remove old observer
        focusObservation?.invalidate()

        // Observe adjustingFocus property (for detecting focus state)
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] device, change in
            guard let self = self else { return }

            let isAdjusting = change.newValue ?? false

            Task { @MainActor in
                self.isAdjustingFocus = isAdjusting
            }
        }
    }

    /// Stop observing focus state
    private func stopFocusObservation() {
        focusObservation?.invalidate()
        focusObservation = nil
    }

    // MARK: - Macro Mode Observation

    /// Start observing lens position (for macro detection)
    private func startLensPositionObservation(for device: AVCaptureDevice) {
        // Remove old observer
        lensPositionObservation?.invalidate()


        // Observe lensPosition property (0.0 = infinity, 1.0 = closest focus)
        lensPositionObservation = device.observe(\.lensPosition, options: [.new, .initial]) { [weak self] device, change in
            guard let self = self else { return }
            guard let lensPosition = change.newValue else { return }

            Task { @MainActor in
                self.handleLensPositionChange(lensPosition: lensPosition)
            }
        }

    }

    /// Stop lens position observation
    private func stopLensPositionObservation() {
        lensPositionObservation?.invalidate()
        lensPositionObservation = nil
    }

    /// Current lensPosition (for per-frame macro condition detection)
    private var currentLensPosition: Float = 1.0

    /// Handle lens position change (update current lensPosition)
    private func handleLensPositionChange(lensPosition: Float) {
        // Skip if camera is stopped
        guard isRunning else { return }

        // Store current lensPosition (for per-frame detection)
        currentLensPosition = lensPosition

        // Macro detection logic moved to checkMacroConditionPerFrame()
        // Indicator state also managed by macroManager
    }

    /// Per-frame macro condition check (called from video frame callback)
    private func checkMacroConditionPerFrame(lensPosition: Float) {
        let action = macroManager.checkConditions(
            lensPosition: lensPosition,
            isAdjustingFocus: isAdjustingFocus,
            currentZoom: currentZoomFactor,
            isBackCamera: currentDevice == .back,
            hasUltraWide: ultraWideDevice != nil
        )

        switch action {
        case .activate:
            activateMacroMode()
        case .deactivate:
            deactivateMacroMode()
        case .none:
            break
        }
    }

    /// Activate macro mode (switch to ultra-wide + 2x crop)
    private func activateMacroMode() {
        guard !isMacroModeActive else { return }
        guard let ultraWide = ultraWideDevice else { return }

        macroSwitchingManager.activateMacroMode(
            ultraWideDevice: ultraWide,
            context: createMacroSwitchContext(),
            macroManager: macroManager,
            portraitManager: portraitManager,
            currentZoom: currentZoomFactor
        )
    }

    /// Exit macro mode (switch back to Triple Camera)
    private func deactivateMacroMode() {
        guard isMacroModeActive else { return }
        guard let tripleCamera = getCaptureDevice(for: .back) else {
            logger.error("Cannot get Triple Camera device for macro deactivation")
            return
        }

        macroSwitchingManager.deactivateMacroMode(
            tripleCameraDevice: tripleCamera,
            context: createMacroSwitchContext(),
            macroManager: macroManager
        )
    }

    /// Create macro switch context
    private func createMacroSwitchContext() -> MacroSwitchingManager.SwitchContext {
        MacroSwitchingManager.SwitchContext(
            captureSession: captureSession,
            currentInput: deviceInput,
            videoOutput: videoOutput,
            sessionQueue: sessionQueue,
            videoOutputQueue: videoOutputQueue,
            previewLayer: previewLayer,
            updateDeviceInput: { [weak self] input in
                self?.deviceInput = input
            },
            videoDelegate: self,
            updateRotationCoordinator: { [weak self] device in
                guard let self = self else { return }
                self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                    device: device,
                    previewLayer: self.previewLayer
                )
            },
            restartObservers: { [weak self] device in
                self?.startFocusObservation(for: device)
                self?.startLensPositionObservation(for: device)
            },
            updateZoom: { [weak self] zoom in
                self?.zoomManager?.updateCurrentZoom(zoom)
            }
        )
    }

    // MARK: - Private Methods

    /// Ensure depth data and related features are enabled (for Portrait mode)
    /// Called after session recovery or configuration change to prevent system reset
    private func ensureDepthDataEnabled() {
        guard let photoOutput = self.photoOutput else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Check and enable depth data capture (required for Portrait mode)
            if photoOutput.isDepthDataDeliverySupported && !photoOutput.isDepthDataDeliveryEnabled {
                photoOutput.isDepthDataDeliveryEnabled = true
                self.logger.info("✅ Re-enabled depth data delivery after session change")
            }

            // Check and enable Portrait Effects Matte
            if photoOutput.isPortraitEffectsMatteDeliverySupported && !photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                photoOutput.isPortraitEffectsMatteDeliveryEnabled = true
                self.logger.info("✅ Re-enabled Portrait Effects Matte after session change")
            }

            // Check and enable Semantic Segmentation Mattes
            let availableMatteTypes = photoOutput.availableSemanticSegmentationMatteTypes
            if !availableMatteTypes.isEmpty && photoOutput.enabledSemanticSegmentationMatteTypes.isEmpty {
                photoOutput.enabledSemanticSegmentationMatteTypes = availableMatteTypes
                let matteTypeNames = availableMatteTypes.map { $0.rawValue }.joined(separator: ", ")
                self.logger.info("✅ Re-enabled semantic segmentation mattes after session change: [\(matteTypeNames)]")
            }
        }
    }

    /// Enable depth data, portrait effects matte, and semantic segmentation on a photo output.
    /// Must be called on sessionQueue after output is added to session.
    private func configurePhotoOutputCapabilities(_ output: AVCapturePhotoOutput) {
        if output.isDepthDataDeliverySupported {
            output.isDepthDataDeliveryEnabled = true
        }
        if output.isPortraitEffectsMatteDeliverySupported {
            output.isPortraitEffectsMatteDeliveryEnabled = true
        }
        let availableMatteTypes = output.availableSemanticSegmentationMatteTypes
        if !availableMatteTypes.isEmpty {
            output.enabledSemanticSegmentationMatteTypes = availableMatteTypes
        }
    }

    /// Configure photo output for highest quality capture (dimensions, quality prioritization,
    /// responsive capture, live photo, deferred delivery, distortion correction).
    /// Must be called on sessionQueue with a valid device.
    private func configurePhotoOutputQuality(_ output: AVCapturePhotoOutput, device: AVCaptureDevice) {
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        if let maxDimensions = supportedDimensions.last {
            output.maxPhotoDimensions = maxDimensions
        }
        output.maxPhotoQualityPrioritization = .quality
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = true
        }
        if output.isFastCapturePrioritizationSupported {
            output.isFastCapturePrioritizationEnabled = false
        }
        if output.isLivePhotoCaptureSupported {
            output.isLivePhotoCaptureEnabled = true
        }
        if output.isAutoDeferredPhotoDeliverySupported {
            output.isAutoDeferredPhotoDeliveryEnabled = true
        }
        if output.isContentAwareDistortionCorrectionSupported {
            output.isContentAwareDistortionCorrectionEnabled = true
        }
    }

    /// Set zoom factor to defaultZoom (clamped to device range), falling back to minZoom.
    /// Device must already be locked for configuration.
    private func setDefaultZoom(on device: AVCaptureDevice, defaultZoom: CGFloat) {
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        if defaultZoom >= minZoom && defaultZoom <= maxZoom {
            device.videoZoomFactor = defaultZoom
        } else {
            device.videoZoomFactor = minZoom
        }
    }

    /// Check camera permissions
    private func checkAuthorization() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            sessionQueue.suspend()
            defer { sessionQueue.resume() }  // Guarantee resume even if task is cancelled

            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                logger.error("Camera access denied by user")
                throw CameraError.permissionDenied
            }
        case .denied, .restricted:
            logger.error("Camera access denied or restricted")
            throw CameraError.permissionDenied
        @unknown default:
            logger.error("Unknown camera authorization status")
            throw CameraError.permissionDenied
        }
    }

    /// Configure camera session
    private func configureSession() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CameraError.unknown("Self is nil"))
                    return
                }

                do {
                    self.captureSession.beginConfiguration()
                    defer { self.captureSession.commitConfiguration() }

                    // 🔧 Safety check: ensure no existing inputs/outputs before configuring
                    // This handles edge cases where forceResetSession may not have fully completed
                    if !self.captureSession.inputs.isEmpty {
                        self.logger.warning("⚠️ Session has \(self.captureSession.inputs.count) existing inputs - removing...")
                        for input in self.captureSession.inputs {
                            self.captureSession.removeInput(input)
                        }
                    }
                    if !self.captureSession.outputs.isEmpty {
                        self.logger.warning("⚠️ Session has \(self.captureSession.outputs.count) existing outputs - removing...")
                        for output in self.captureSession.outputs {
                            self.captureSession.removeOutput(output)
                        }
                    }

                    // Configure session preset - photo quality
                    if self.captureSession.canSetSessionPreset(.photo) {
                        self.captureSession.sessionPreset = .photo
                    } else if self.captureSession.canSetSessionPreset(.high) {
                        self.captureSession.sessionPreset = .high
                    }

                    // Get device
                    guard let device = self.getCaptureDevice(for: .back) else {
                        throw CameraError.deviceNotAvailable
                    }

                    // Add input
                    let deviceInput = try AVCaptureDeviceInput(device: device)
                    guard self.captureSession.canAddInput(deviceInput) else {
                        self.logger.error("Cannot add device input - inputs: \(self.captureSession.inputs.count), outputs: \(self.captureSession.outputs.count)")
                        throw CameraError.sessionConfigurationFailed
                    }
                    self.captureSession.addInput(deviceInput)
                    self.deviceInput = deviceInput

                    // Add photo output
                    let photoOutput = AVCapturePhotoOutput()
                    guard self.captureSession.canAddOutput(photoOutput) else {
                        self.logger.error("Cannot add photo output")
                        throw CameraError.sessionConfigurationFailed
                    }
                    self.captureSession.addOutput(photoOutput)
                    self.photoOutput = photoOutput

                    self.configurePhotoOutputCapabilities(photoOutput)
                    self.configurePhotoOutputQuality(photoOutput, device: device)

                    // Add video data output (for subject detection)
                    let videoOutput = AVCaptureVideoDataOutput()
                    videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    videoOutput.alwaysDiscardsLateVideoFrames = true
                    // Set delegate synchronously on videoOutputQueue (safe during configuration)
                    videoOutput.setSampleBufferDelegate(self, queue: self.videoOutputQueue)

                    guard self.captureSession.canAddOutput(videoOutput) else {
                        self.logger.error("Cannot add video output")
                        throw CameraError.sessionConfigurationFailed
                    }
                    self.captureSession.addOutput(videoOutput)
                    self.videoOutput = videoOutput

                    // Initialize rotation coordinator
                    self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                        device: device,
                        previewLayer: self.previewLayer
                    )

                    // Start focus state observation
                    Task { @MainActor in
                        self.startFocusObservation(for: device)
                        self.startLensPositionObservation(for: device)
                    }

                    // Get ultra-wide device (for macro mode)
                    if let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
                        Task { @MainActor in
                            self.ultraWideDevice = ultraWide
                        }
                    }

                    // Update zoom capabilities and available presets
                    Task { @MainActor in
                        self.updateZoomCapabilities(for: device)
                    }

                    // Configure device parameters (zoom, focus, exposure)
                    do {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }

                        // 1. Set default zoom (main camera 48MP, displayed as "1" in UI)
                        // Triple Camera: system 1.0x=ultra-wide, 2.0x=main 48MP, 3.0x=telephoto
                        // UI mapping: .5 → 1.0x, 1 → 2.0x, 2 → 4.0x, 3 → 6.0x
                        let defaultZoom = config.zoom.defaultBackCameraZoom
                        let minZoom = device.minAvailableVideoZoomFactor
                        let maxZoom = device.maxAvailableVideoZoomFactor

                        if defaultZoom >= minZoom && defaultZoom <= maxZoom {
                            device.videoZoomFactor = defaultZoom
                            Task { @MainActor in
                                self.zoomManager?.updateCurrentZoom(defaultZoom)
                            }
                        } else if 1.0 >= minZoom && 1.0 <= maxZoom {
                            device.videoZoomFactor = 1.0
                            Task { @MainActor in
                                self.zoomManager?.updateCurrentZoom(1.0)
                            }
                        }

                        // 2. Configure exposure mode
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }

                        // 3. Configure white balance (continuous auto for accurate colors)
                        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                            device.whiteBalanceMode = .continuousAutoWhiteBalance
                        }

                        // 4. Enable automatic low light boost
                        if device.isLowLightBoostSupported {
                            device.automaticallyEnablesLowLightBoostWhenAvailable = true
                        }

                        // 5. Configure focus mode based on autofocus system type
                        // Phase detection: fast & subtle, use continuous AF freely
                        // Contrast detection: slower with visible "hunting", enable smooth AF
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }

                        // Enable smooth autofocus for contrast detection systems
                        // Reduces "focus hunting" which is more visible on older/front cameras
                        let afSystem = device.activeFormat.autoFocusSystem
                        if afSystem == .contrastDetection && device.isSmoothAutoFocusSupported {
                            device.isSmoothAutoFocusEnabled = true
                            self.logger.info("✅ Smooth AutoFocus enabled (contrast detection system)")
                        }

                        // 6. Enable subject area change monitoring (iOS 17+ responsive focus)
                        // When the subject moves significantly, system triggers notification for refocus
                        device.isSubjectAreaChangeMonitoringEnabled = true
                    } catch {
                        self.logger.error("❌ Failed to configure device: \(error.localizedDescription)")
                    }
                    continuation.resume()
                } catch {
                    self.logger.error("Session configuration failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Start session
    private func startSession() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }

                self.captureSession.startRunning()

                // Verify session start status
                if !self.captureSession.isRunning {
                    self.logger.error("❌ Session failed to start running!")
                }

                continuation.resume()
            }
        }

        // Pre-warm Content-Aware Distortion Correction asynchronously after session starts
        // This avoids ~300ms delay on first capture without blocking the UI
        sessionQueue.async { [weak self] in
            guard let self = self, let photoOutput = self.photoOutput else { return }
            if photoOutput.isContentAwareDistortionCorrectionSupported {
                photoOutput.isContentAwareDistortionCorrectionEnabled = true
                self.logger.info("✅ Content-Aware Distortion Correction pre-warmed")
            }
        }
    }

    /// Get camera device for specified position
    nonisolated private func getCaptureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // iPhone 15 Pro: Prefer multi-camera system (Triple Camera)
        // This provides full 24MP main camera + multi-lens switching capability

        // 1. Preferred: Triple Camera (iPhone 15 Pro/Max, 14 Pro/Max, 13 Pro/Max)
        if let tripleCamera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: position) {
            return tripleCamera
        }

        // 2. Secondary: Dual Wide Camera (iPhone 13/14 standard)
        if let dualWideCamera = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: position) {
            return dualWideCamera
        }

        // 3. Fallback: Dual Camera (older Plus models)
        if let dualCamera = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: position) {
            return dualCamera
        }

        // 4. Last resort: Single lens (basic models or front camera)
        if let wideAngleCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) {
            return wideAngleCamera
        }

        logger.error("❌ No suitable camera device found")
        return nil
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {


    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error = error {
            logger.error("Error capturing photo: \(error.localizedDescription)")
            // Cancel Live Photo capture on error
            Task {
                await livePhotoManager.cancelCapture(id: photo.resolvedSettings.uniqueID)
            }
            Task { @MainActor [weak self] in
                self?.finishCaptureLifecycle()
            }
            return
        }

        let photoID = photo.resolvedSettings.uniqueID
        let isLivePhoto = photo.resolvedSettings.livePhotoMovieDimensions.width > 0

        if isLivePhoto {
            // Live Photo: Register photo part, wait for movie to complete
            Task {
                await livePhotoManager.completePhotoCapture(id: photoID, photo: photo)
                logger.info("📸 Live Photo: Photo part completed, waiting for movie...")
            }
        }

        // 📸 Send photo to stream (for both regular and Live Photo)
        // Use background task to ensure location fetch + photo delivery completes even if app exits
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Background task to protect location fetch (may take up to 3s if no cached location)
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "PhotoLocationFetch") {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }

            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }

            // Request location (returns cached immediately if available, else waits up to 3s)
            let location = await self.locationManager.requestInstantLocation()

            // Send photo to stream
            self.addToPhotoStream?((photo: photo, location: location))

            // Photo capture complete
            Task { @MainActor in
                self.finishCaptureLifecycle()
            }
        }
    }

    /// Live Photo movie file processing complete callback
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error = error {
            logger.error("❌ Live Photo movie processing error: \(error.localizedDescription)")
            Task {
                await livePhotoManager.cancelCapture(id: resolvedSettings.uniqueID)
            }
            return
        }

        let photoID = resolvedSettings.uniqueID
        logger.info("🎬 Live Photo: Movie processing completed for \(photoID)")

        Task {
            await livePhotoManager.completeMovieProcessing(id: photoID)
        }
    }

    /// Deferred photo processing callback (Deferred Photo Processing)
    /// When isAutoDeferredPhotoDeliveryEnabled = true, system may return proxy object instead of final photo
    /// Background will continue processing Deep Fusion / Photonic Engine computational photography, auto-update Photos Library when complete
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
        error: Error?
    ) {
        if let error = error {
            logger.error("❌ Deferred photo proxy error: \(error.localizedDescription)")
            Task { @MainActor [weak self] in
                self?.finishCaptureLifecycle()
            }
            return
        }

        guard let proxy = deferredPhotoProxy else {
            logger.warning("⚠️ Deferred photo proxy is nil")
            return
        }

        // Get location info and save proxy photo
        // Use background task to ensure location fetch + photo delivery completes even if app exits
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Background task to protect location fetch
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "DeferredPhotoLocationFetch") {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
            }

            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                }
            }

            let location = await self.locationManager.requestInstantLocation()

            // Send proxy photo to stream (system will complete processing in background and auto-update)
            self.addToDeferredPhotoStream?((proxy: proxy, location: location))

            // Restore focus and exposure
            Task { @MainActor in
                self.finishCaptureLifecycle()
            }
        }
    }
}
// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    // Note: This is called on videoOutputQueue, NOT on main thread
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Extract pixel buffer before crossing actor boundary (CMSampleBuffer is not Sendable)
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // All processing happens on main thread
        Task { @MainActor [weak self, pixelBuffer] in
            guard let self = self else { return }

            // Skip processing if camera is stopped
            guard self.isRunning else { return }

            // Store latest frame for live caption feature
            self._latestPixelBuffer = pixelBuffer

            // Pass pixel buffer to subject detector (processes asynchronously internally)
            self.subjectDetector.detectSubjects(in: pixelBuffer, isFrontCamera: self.isFrontCamera)
        }
    }
}

// MARK: - Frame Capture

extension CameraManager {
    /// Capture current camera frame as UIImage from the latest video data output buffer
    func captureCurrentFrame() -> UIImage? {
        guard let pixelBuffer = _latestPixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        // Video pixel buffers are always landscape; apply correct orientation
        let orientation: UIImage.Orientation = isFrontCamera ? .leftMirrored : .right
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
    }
}

// MARK: - Video Recording

extension CameraManager {

    /// Switch between photo and video mode
    /// - Parameters:
    ///   - mode: The camera mode to switch to
    ///   - completion: Called on main thread when configuration is complete
    func setCameraMode(_ mode: CameraMode, completion: (() -> Void)? = nil) {
        guard mode != cameraMode else {
            completion?()
            return
        }

        // Stop any ongoing recording
        if isRecording {
            stopRecording()
        }

        cameraMode = mode

        sessionQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion?() }
                return
            }

            // Use beginConfiguration/commitConfiguration without stopping session
            // This allows seamless transition without preview interruption
            self.captureSession.beginConfiguration()

            if mode == .video {
                self.configureForVideoMode()
            } else {
                self.configureForPhotoMode()
            }

            self.captureSession.commitConfiguration()

            // For video mode on front camera: wait for exposure to stabilize
            // This prevents dark first frames when user starts recording
            if mode == .video, let device = self.deviceInput?.device, device.position == .front {
                // Wait up to 300ms for exposure to stabilize after format change
                let startWait = Date()
                let maxWait: TimeInterval = 0.3
                while device.isAdjustingExposure && Date().timeIntervalSince(startWait) < maxWait {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }

            // Ensure zoom state is synced before calling completion
            // This must happen on main thread before completion callback
            DispatchQueue.main.async { [weak self] in
                guard let self = self else {
                    completion?()
                    return
                }

                // Sync zoom state from device (format change may have reset it)
                if let device = self.deviceInput?.device {
                    let deviceZoom = device.videoZoomFactor
                    self.currentZoomFactor = deviceZoom
                    self.zoomManager?.updateCurrentZoom(deviceZoom)
                }

                completion?()
            }
        }
    }

    /// Configure session for video mode
    private func configureForVideoMode() {
        guard let device = deviceInput?.device else { return }

        // 🔧 CRITICAL FIX: Temporarily remove photo output when in video mode
        // Photo output with depth data enabled conflicts with video format settings
        // This fixes error -11872 "Cannot Record"
        if let output = photoOutput {
            captureSession.removeOutput(output)
            logger.info("📹 Removed photo output for video mode")
        }

        // 🔧 Also remove video data output (subject detection) during video recording
        // It may conflict with movie output when using custom formats
        if let output = videoOutput {
            captureSession.removeOutput(output)
            logger.info("📹 Removed video data output for video mode")
        }

        // 🔧 Configure video format FIRST (before adding outputs)
        // Setting activeFormat automatically sets session to AVCaptureSessionPresetInputPriority
        // This allows custom format without preset conflicts
        configureVideoFormat(for: device)

        // Add audio input
        if audioInput == nil {
            if let audioDevice = AVCaptureDevice.default(for: .audio) {
                do {
                    let input = try AVCaptureDeviceInput(device: audioDevice)
                    if captureSession.canAddInput(input) {
                        captureSession.addInput(input)
                        audioInput = input
                    }
                } catch {
                    logger.error("Failed to add audio input: \(error.localizedDescription)")
                }
            }
        }

        // Add movie output AFTER format is configured
        // 🔧 Always check if movieOutput is in the session, not just if it's nil
        // This handles the case where movieOutput was removed but reference wasn't cleared
        let needsMovieOutput = movieOutput == nil || !captureSession.outputs.contains(where: { $0 === movieOutput })

        if needsMovieOutput {
            // Remove stale reference if exists
            if let staleOutput = movieOutput {
                if captureSession.outputs.contains(staleOutput) {
                    captureSession.removeOutput(staleOutput)
                }
                movieOutput = nil
            }

            let output = AVCaptureMovieFileOutput()
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                movieOutput = output
                logger.info("📹 Added movie output for video recording")
            } else {
                logger.error("❌ Cannot add movie output to session")
            }
        } else {
            logger.info("📹 Movie output already configured")
        }

        // Configure video settings on the movie output connection
        if let output = movieOutput, let connection = output.connection(with: .video) {
            // Apply stabilization mode
            // Front camera: no stabilization (matches native Camera, avoids FOV crop mismatch)
            // Back camera: apply user-selected stabilization mode
            let isFront = device.position == .front
            if connection.isVideoStabilizationSupported {
                if isFront {
                    // Front camera: disable stabilization to match preview FOV
                    connection.preferredVideoStabilizationMode = .off
                    logger.info("📹 Front camera: stabilization disabled")
                } else {
                    switch self.videoStabilizationMode {
                    case .standard:
                        connection.preferredVideoStabilizationMode = .standard
                    case .action:
                        connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                    }
                    logger.info("📹 Stabilization mode set: \(self.videoStabilizationMode.rawValue)")
                }
            }

            // Configure HEVC encoding with HDR support (native Camera uses HEVC + HDR)
            // Bitrate: ~50 Mbps for 4K, ~20 Mbps for 1080p (similar to native Camera)
            // HDR requires higher bitrate to preserve color depth
            let bitrate = isFront ? 20_000_000 : 60_000_000  // 1080p vs 4K HDR

            if output.availableVideoCodecTypes.contains(.hevc) {
                // Use Main10 profile for HDR/10-bit support (preserves HDR metadata)
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitrate,
                        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 30  // Keyframe every 1 second at 30fps
                    ]
                ]
                output.setOutputSettings(videoSettings, for: connection)
                logger.info("📹 HEVC Main10 (HDR) encoding configured @ \(bitrate / 1_000_000) Mbps")
            } else if output.availableVideoCodecTypes.contains(.h264) {
                // Fallback to H.264
                let h264Bitrate = isFront ? 25_000_000 : 60_000_000
                let videoSettings: [String: Any] = [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: h264Bitrate,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 30
                    ]
                ]
                output.setOutputSettings(videoSettings, for: connection)
                logger.info("📹 H.264 encoding configured @ \(h264Bitrate / 1_000_000) Mbps")
            }

            logger.info("📹 Video connection configured: active=\(connection.isActive)")
        } else {
            logger.error("❌ No video connection available for movie output")
        }

        // Reset zoom after format change
        // Video format has different FOV, need to ensure zoom is at baseline
        // Front camera in video mode: always 1.0x (no zoom adjustment allowed)
        // Back camera in video mode: default 2.0x (UI 1x)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let isFront = device.position == .front
            setDefaultZoom(on: device, defaultZoom: isFront ? 1.0 : 2.0)
        } catch {
            logger.error("Failed to reset video zoom: \(error.localizedDescription)")
        }
    }

    /// Four-char codec string from a format description's media sub-type
    private func codecString(for format: AVCaptureDevice.Format) -> String {
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return String(format: "%c%c%c%c",
                      (type >> 24) & 0xFF, (type >> 16) & 0xFF,
                      (type >> 8) & 0xFF, type & 0xFF)
    }

    /// Search `device.formats` for the best standard-codec format at the given resolution
    private func findBestVideoFormat(
        for device: AVCaptureDevice,
        targetWidth: Int32,
        targetHeight: Int32,
        preferredFrameRate: Float64 = 30
    ) -> (format: AVCaptureDevice.Format, frameRate: Float64)? {
        let allowedCodecs = ["420v", "420f", "BGRA", "x420"]
        var bestFormat: AVCaptureDevice.Format?
        var bestFrameRate: Float64 = 0

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == targetWidth && dimensions.height == targetHeight else { continue }

            let codec = codecString(for: format)
            guard !codec.hasPrefix("ap"),
                  allowedCodecs.contains(where: { codec.hasPrefix($0) }) else { continue }

            let isHDR = codec.hasPrefix("x420")

            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate >= preferredFrameRate {
                    let currentIsHDR = bestFormat.map { codecString(for: $0).hasPrefix("x420") } ?? false
                    if bestFormat == nil || bestFrameRate != preferredFrameRate || (isHDR && !currentIsHDR) {
                        bestFormat = format
                        bestFrameRate = preferredFrameRate
                    }
                } else if bestFormat == nil && range.maxFrameRate >= 24 {
                    bestFormat = format
                    bestFrameRate = range.maxFrameRate
                }
            }
        }

        guard let format = bestFormat else { return nil }
        return (format, bestFrameRate)
    }

    /// Configure video format for the device (matching native Camera app: 4K 30fps back, 1080p 30fps front)
    private func configureVideoFormat(for device: AVCaptureDevice) {
        let isFrontCamera = device.position == .front
        let targetWidth: Int32 = isFrontCamera ? 1920 : 3840
        let targetHeight: Int32 = isFrontCamera ? 1080 : 2160

        var result = findBestVideoFormat(for: device, targetWidth: targetWidth, targetHeight: targetHeight)

        // Fallback to 1080p if 4K not available on back camera
        if result == nil && !isFrontCamera {
            logger.info("📹 4K not available, falling back to 1080p")
            result = findBestVideoFormat(for: device, targetWidth: 1920, targetHeight: 1080)
        }

        guard let (format, bestFrameRate) = result else {
            logger.warning("No suitable video format found for \(isFrontCamera ? "front" : "back") camera")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let codec = codecString(for: format)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(bestFrameRate))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }

            let isHDR = codec.hasPrefix("x420")
            logger.info("📹 Video format configured: \(isFrontCamera ? "front" : "back") camera @ \(Int(dimensions.width))x\(Int(dimensions.height)) \(Int(bestFrameRate))fps, codec: \(codec)\(isHDR ? " (HDR)" : "")")
        } catch {
            logger.error("Failed to configure video format: \(error.localizedDescription)")
        }
    }

    /// Configure session for photo mode
    private func configureForPhotoMode() {
        // Remove movie output
        if let output = movieOutput {
            captureSession.removeOutput(output)
            movieOutput = nil
        }

        // Remove audio input
        if let input = audioInput {
            captureSession.removeInput(input)
            audioInput = nil
        }

        // Restore photo session preset
        if captureSession.canSetSessionPreset(.photo) {
            captureSession.sessionPreset = .photo
        }

        // 🔧 Re-add video data output if it was removed for video mode (for subject detection)
        if let output = videoOutput, !captureSession.outputs.contains(output) {
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                // Restore delegate
                output.setSampleBufferDelegate(self, queue: videoOutputQueue)
                logger.info("📷 Re-added video data output for photo mode")
            }
        }

        // 🔧 Re-add photo output if it was removed for video mode
        if let output = photoOutput, !captureSession.outputs.contains(output) {
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
                logger.info("📷 Re-added photo output for photo mode")

                // Re-configure photo output settings (depth, mattes, quality)
                if let device = deviceInput?.device {
                    configurePhotoOutputCapabilities(output)
                    configurePhotoOutputQuality(output, device: device)
                }
            } else {
                logger.error("❌ Cannot re-add photo output to session")
            }
        }

        // Reset zoom to default after switching back to photo mode
        // Front camera: 1.0x, Back camera: 2.0x (UI 1x)
        if let device = deviceInput?.device {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                let isFront = device.position == .front
                setDefaultZoom(on: device, defaultZoom: isFront ? 1.0 : 2.0)
            } catch {
                logger.error("Failed to restore photo format: \(error.localizedDescription)")
            }
        }
    }

    /// Start video recording
    func startRecording() {
        // 🔧 Detailed logging to diagnose why recording might not start
        guard cameraMode == .video else {
            logger.warning("⚠️ startRecording called but cameraMode=\(self.cameraMode.rawValue), not video")
            return
        }
        guard !isRecording else {
            logger.warning("⚠️ startRecording called but already recording")
            return
        }
        guard let output = movieOutput else {
            logger.error("❌ startRecording failed: movieOutput is nil")
            // Try to recover by reconfiguring video mode
            if deviceInput?.device != nil {
                logger.info("🔄 Attempting to reconfigure video mode...")
                sessionQueue.async { [weak self] in
                    self?.configureForVideoMode()
                }
            }
            return
        }

        // Verify video connection is available and active
        guard let connection = output.connection(with: .video) else {
            logger.error("❌ Cannot start recording: no video connection")
            return
        }
        guard connection.isActive else {
            logger.error("❌ Cannot start recording: video connection not active")
            return
        }

        // Create output URL
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        // Apply video orientation
        if let rotationCoordinator = rotationCoordinator {
            connection.videoRotationAngle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
        }

        // Apply stabilization mode (already set in configureForVideoMode, but ensure it's applied)
        // Front camera: no stabilization (matches native Camera, avoids FOV crop)
        let isFrontCamera = deviceInput?.device.position == .front
        if connection.isVideoStabilizationSupported {
            if isFrontCamera {
                connection.preferredVideoStabilizationMode = .off
            } else {
                switch videoStabilizationMode {
                case .standard:
                    connection.preferredVideoStabilizationMode = .standard
                case .action:
                    connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
                }
            }
        }

        // Update state first (show recording UI immediately for responsiveness)
        isRecording = true
        recordingStartTime = Date()
        recordingDuration = 0
        let startDelay: TimeInterval = isFrontCamera ? 0.15 : 0  // 150ms delay for front camera

        if startDelay > 0 {
            sessionQueue.asyncAfter(deadline: .now() + startDelay) { [weak self] in
                guard let self = self, self.isRecording else { return }
                output.startRecording(to: outputURL, recordingDelegate: self)
                self.logger.info("📹 Front camera recording started after \(startDelay)s delay")
            }
        } else {
            // Start recording immediately for back camera
            output.startRecording(to: outputURL, recordingDelegate: self)
        }

        // Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.recordingStartTime else { return }
            Task { @MainActor in
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }

        Haptics.medium()
    }

    /// Stop video recording
    func stopRecording() {
        guard isRecording else { return }

        movieOutput?.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
        Haptics.medium()
    }

    /// Toggle torch for video mode
    func toggleTorch() {
        guard cameraMode == .video else { return }
        guard let device = deviceInput?.device else { return }
        guard device.hasTorch else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if device.torchMode == .off {
                    try device.setTorchModeOn(level: 1.0)
                    Task { @MainActor in
                        self.isTorchEnabled = true
                    }
                } else {
                    device.torchMode = .off
                    Task { @MainActor in
                        self.isTorchEnabled = false
                    }
                }
            } catch {
                self.logger.error("Failed to toggle torch: \(error.localizedDescription)")
            }
        }
    }

    /// Set torch state explicitly
    func setTorch(enabled: Bool) {
        guard cameraMode == .video else { return }
        guard let device = deviceInput?.device else { return }
        guard device.hasTorch else { return }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if enabled {
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }

                Task { @MainActor in
                    self.isTorchEnabled = enabled
                }
            } catch {
                self.logger.error("Failed to set torch: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            self.isRecording = false
            self.recordingDuration = 0
            self.recordingStartTime = nil

            // Turn off torch when recording ends
            if self.isTorchEnabled {
                self.setTorch(enabled: false)
            }

            if let error = error {
                self.logger.error("Recording failed: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: outputFileURL)
                return
            }

            // Emit to video stream for DataModel to handle saving
            let location = self.locationManager.currentLocation
            self.addToVideoStream?((url: outputFileURL, location: location))
        }
    }
}
