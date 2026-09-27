//
//  SubjectLockService.swift
//  CameraStarter
//
//  Main coordinator for subject lock and continuous focus tracking
//  Works across all camera modes (default, shot guidance, video)
//
//  Design principles:
//  - Lock on detected subject and maintain continuous focus
//  - Smooth tracking with Kalman filter prediction
//  - Visual feedback via tracking box overlay
//

import Foundation
import CoreGraphics
import os.log

// MARK: - Lock State

/// Subject lock state
enum SubjectLockState: Equatable {
    case idle               // No subject detected
    case detecting          // Subject detected, not yet locked
    case tracking           // Actively tracking locked subject
    case stable             // Tracking is stable (good for capture)
    case lost               // Subject lost, searching to reacquire

    var isLocked: Bool {
        switch self {
        case .tracking, .stable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Tracked Subject

/// A subject followed across frames.
struct TrackedSubject: Equatable {
    let id: UUID
    let boundingBox: CGRect           // Current bounding box (normalized 0-1)
    let predictedBox: CGRect          // Kalman-predicted next position
    let confidence: Float
    let animalType: String
    let trackingDuration: TimeInterval // How long we've been tracking
    let velocity: CGPoint             // Normalized velocity (units/frame) for interpolation

    init(id: UUID, boundingBox: CGRect, predictedBox: CGRect, confidence: Float, animalType: String, trackingDuration: TimeInterval, velocity: CGPoint = .zero) {
        self.id = id
        self.boundingBox = boundingBox
        self.predictedBox = predictedBox
        self.confidence = confidence
        self.animalType = animalType
        self.trackingDuration = trackingDuration
        self.velocity = velocity
    }

    /// Center point of the bounding box
    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    /// Smoothed center for focus (average of current and predicted)
    var focusPoint: CGPoint {
        CGPoint(
            x: (boundingBox.midX + predictedBox.midX) / 2,
            y: (boundingBox.midY + predictedBox.midY) / 2
        )
    }
}

// MARK: - Subject Lock Service

/// Main service for subject lock and continuous tracking
@MainActor
@Observable
final class SubjectLockService {

    // MARK: - Public State

    /// Current lock state
    private(set) var lockState: SubjectLockState = .idle

    /// Currently tracked subject (nil if not tracking)
    private(set) var trackedSubject: TrackedSubject?

    /// Focus point for camera AF system (updated smoothly)
    private(set) var focusPoint: CGPoint?

    /// Whether tracking is stable
    var isStable: Bool {
        lockState == .stable
    }

    /// Whether we have a locked subject
    var isLocked: Bool {
        lockState.isLocked
    }

    /// Whether the current lock is manual (user-initiated via tap)
    private(set) var isManualLock: Bool = false

    // MARK: - Callbacks

    /// Called when focus point should be updated
    var onFocusPointUpdate: ((CGPoint) -> Void)?

    /// Called when lock state changes (for UI updates)
    var onLockStateChanged: ((SubjectLockState) -> Void)?

    /// Called when stable state is achieved
    var onStableStateAchieved: (() -> Void)?

    // MARK: - Configuration

    /// How long tracking must be stable to trigger stable state (seconds)
    private let stableThreshold: TimeInterval = 0.8

    /// Maximum position change (normalized) to consider "stable"
    /// More lenient to allow for natural hand movement while shooting
    private let stablePositionThreshold: CGFloat = 0.05  // 5% of screen

    /// How long without detection before considering "lost" (seconds)
    private let lostTimeout: TimeInterval = 0.6

    /// Minimum tracking duration before allowing stable state
    private let minTrackingForStable: TimeInterval = 0.2

    // MARK: - Internal State

    private let logger = Logger(subsystem: Log.subsystem, category: "SubjectLock")

    /// Kalman filter for position prediction
    private var kalmanFilter = KalmanFilter2D()

    /// ID of the subject we're locked onto
    private var lockedSubjectID: UUID?

    /// When we started tracking current subject
    private var trackingStartTime: Date?

    /// Last time we saw the subject
    private var lastSeenTime: Date?

    /// Position history for stability calculation
    private var positionHistory: [CGPoint] = []
    private let positionHistorySize = 10

    /// Last few positions for stability check
    private var recentPositions: [CGPoint] = []
    private let recentPositionCount = 5

    /// Smoothed bounding box dimensions (EMA to prevent size jitter)
    private var smoothedWidth: CGFloat = 0
    private var smoothedHeight: CGFloat = 0
    private let sizeSmoothingAlpha: CGFloat = 0.3

    /// When we last achieved stable tracking
    private var stableStartTime: Date?

    // MARK: - Public Methods

    /// Update with new subject detection results
    /// Called every frame from SubjectDetector
    func update(with subjectDetections: [SubjectDetectionResult], primaryID: UUID?) {
        let now = Date()

        // Try to find our locked subject in new detections
        if let lockedID = lockedSubjectID {
            if let matchedSubject = findMatchingSubject(id: lockedID, in: subjectDetections) {
                // Subject still visible - update tracking
                updateTracking(with: matchedSubject, at: now)
            } else {
                // Subject not found - check if lost
                handleSubjectNotFound(at: now)
            }
        } else if !isManualLock {
            // Not locked and not manually locked - look for subject to lock onto
            // Skip auto-lock if user has manually unlocked (isManualLock will be reset on next manual lock)
            if let bestSubject = selectBestSubjectToTrack(from: subjectDetections, primaryID: primaryID) {
                startTracking(subject: bestSubject, at: now, manual: false)
            } else {
                // No subjects detected
                if lockState != .idle {
                    transitionTo(.idle)
                }
            }
        } else {
            // Manual lock mode but no locked subject - stay idle until user taps again
            if lockState != .idle {
                transitionTo(.idle)
            }
        }

        // Update focus point for camera
        updateFocusPoint()
    }

    /// Manually lock onto a specific subject (e.g., user tap)
    func lockOn(subject: SubjectDetectionResult) {
        let now = Date()
        isManualLock = true
        startTracking(subject: subject, at: now, manual: true)
        logger.info("Manual lock on subject: \(subject.animalType)")
    }

    /// Release current lock and return to auto mode
    func unlock() {
        lockedSubjectID = nil
        trackedSubject = nil
        trackingStartTime = nil
        lastSeenTime = nil
        positionHistory.removeAll()
        recentPositions.removeAll()
        stableStartTime = nil
        kalmanFilter.reset()
        smoothedWidth = 0
        smoothedHeight = 0
        isManualLock = false  // Return to auto detection mode
        transitionTo(.idle)
        focusPoint = nil
        logger.info("Subject lock released, returning to auto mode")
    }

    /// Release current lock but stay in manual mode (user can tap to select another)
    func unlockKeepManualMode() {
        lockedSubjectID = nil
        trackedSubject = nil
        trackingStartTime = nil
        lastSeenTime = nil
        positionHistory.removeAll()
        recentPositions.removeAll()
        stableStartTime = nil
        kalmanFilter.reset()
        smoothedWidth = 0
        smoothedHeight = 0
        // Keep isManualLock = true so auto-detection doesn't kick in
        transitionTo(.idle)
        focusPoint = nil
        logger.info("Subject lock released, staying in manual mode")
    }

    /// Reset all state
    func reset() {
        unlock()
    }

    // MARK: - Private Methods

    private func findMatchingSubject(id: UUID, in subjects: [SubjectDetectionResult]) -> SubjectDetectionResult? {
        // First try exact ID match
        if let exact = subjects.first(where: { $0.id == id }) {
            return exact
        }

        // If no exact match, try position-based matching
        // This handles cases where Vision assigns new IDs
        guard let lastSubject = trackedSubject else { return nil }

        // Use generous threshold - 25% of screen distance
        // This allows for camera movement while keeping lock
        let matchThreshold: CGFloat = 0.25

        // Also consider bounding box overlap for better matching
        for subject in subjects {
            let distance = hypot(
                subject.boundingBox.midX - lastSubject.boundingBox.midX,
                subject.boundingBox.midY - lastSubject.boundingBox.midY
            )

            // Check if boxes overlap significantly (IoU-like check)
            let intersection = subject.boundingBox.intersection(lastSubject.boundingBox)
            let hasOverlap = !intersection.isNull && intersection.width > 0 && intersection.height > 0

            if distance < matchThreshold || hasOverlap {
                // Update our locked ID to the new one
                lockedSubjectID = subject.id
                return subject
            }
        }

        return nil
    }

    private func selectBestSubjectToTrack(from subjects: [SubjectDetectionResult], primaryID: UUID?) -> SubjectDetectionResult? {
        guard !subjects.isEmpty else { return nil }

        // Prefer the primary subject (already selected by SubjectDetector)
        if let primaryID = primaryID,
           let primary = subjects.first(where: { $0.id == primaryID }) {
            return primary
        }

        // Otherwise take the most confident detection
        return subjects.max(by: { $0.confidence < $1.confidence })
    }

    private func startTracking(subject: SubjectDetectionResult, at time: Date, manual: Bool = false) {
        lockedSubjectID = subject.id
        trackingStartTime = time
        lastSeenTime = time
        positionHistory.removeAll()
        recentPositions.removeAll()
        stableStartTime = nil

        // Use displayBoundingBox (prefers head, falls back to body)
        let box = subject.displayBoundingBox
        let center = CGPoint(x: box.midX, y: box.midY)
        kalmanFilter.reset()
        kalmanFilter.update(measurement: center)
        smoothedWidth = box.width
        smoothedHeight = box.height

        // Create tracked subject
        trackedSubject = TrackedSubject(
            id: subject.id,
            boundingBox: box,
            predictedBox: box,
            confidence: subject.confidence,
            animalType: subject.animalType,
            trackingDuration: 0
        )

        transitionTo(.detecting)
        logger.debug("Started tracking subject: \(subject.animalType), manual: \(manual)")
    }

    private func updateTracking(with subject: SubjectDetectionResult, at time: Date) {
        lastSeenTime = time

        // Use displayBoundingBox (prefers head, falls back to body)
        let box = subject.displayBoundingBox
        let center = CGPoint(x: box.midX, y: box.midY)

        // Update Kalman filter
        kalmanFilter.update(measurement: center)
        let predicted = kalmanFilter.predict()
        let smoothedCenter = kalmanFilter.currentPosition()

        // Smooth size with EMA to prevent dimension jitter
        smoothedWidth = sizeSmoothingAlpha * box.width + (1 - sizeSmoothingAlpha) * smoothedWidth
        smoothedHeight = sizeSmoothingAlpha * box.height + (1 - sizeSmoothingAlpha) * smoothedHeight

        // Calculate smoothed bounding box (Kalman-filtered center + EMA-smoothed size)
        let smoothedBox = CGRect(
            x: smoothedCenter.x - smoothedWidth / 2,
            y: smoothedCenter.y - smoothedHeight / 2,
            width: smoothedWidth,
            height: smoothedHeight
        )

        // Calculate predicted bounding box
        let predictedBox = CGRect(
            x: predicted.x - smoothedWidth / 2,
            y: predicted.y - smoothedHeight / 2,
            width: smoothedWidth,
            height: smoothedHeight
        )

        // Update position history (use smoothed center for stability check)
        positionHistory.append(smoothedCenter)
        if positionHistory.count > positionHistorySize {
            positionHistory.removeFirst()
        }

        recentPositions.append(smoothedCenter)
        if recentPositions.count > recentPositionCount {
            recentPositions.removeFirst()
        }

        // Calculate tracking duration
        let duration = time.timeIntervalSince(trackingStartTime ?? time)

        // Update tracked subject with smoothed bounding box
        // This prevents UI jitter from raw Vision detection noise
        trackedSubject = TrackedSubject(
            id: subject.id,
            boundingBox: smoothedBox,  // Use smoothed position instead of raw
            predictedBox: predictedBox,
            confidence: subject.confidence,
            animalType: subject.animalType,
            trackingDuration: duration,
            velocity: kalmanFilter.currentVelocity()
        )

        // Check stability and update state
        updateTrackingState(at: time, duration: duration)
    }

    private func updateTrackingState(at time: Date, duration: TimeInterval) {
        // Need minimum tracking time before checking stability
        guard duration >= minTrackingForStable else {
            if lockState != .tracking && lockState != .detecting {
                transitionTo(.tracking)
            } else if lockState == .detecting {
                transitionTo(.tracking)
            }
            return
        }

        // Check if tracking is stable
        let isPositionStable = checkPositionStability()

        if isPositionStable {
            if stableStartTime == nil {
                stableStartTime = time
            }

            let stableDuration = time.timeIntervalSince(stableStartTime ?? time)
            if stableDuration >= stableThreshold {
                if lockState != .stable {
                    transitionTo(.stable)
                    onStableStateAchieved?()
                }
            } else {
                if lockState != .tracking {
                    transitionTo(.tracking)
                }
            }
        } else {
            stableStartTime = nil
            if lockState != .tracking {
                transitionTo(.tracking)
            }
        }
    }

    private func checkPositionStability() -> Bool {
        guard recentPositions.count >= recentPositionCount else {
            return false
        }

        // Calculate variance of recent positions
        let avgX = recentPositions.map(\.x).reduce(0, +) / CGFloat(recentPositions.count)
        let avgY = recentPositions.map(\.y).reduce(0, +) / CGFloat(recentPositions.count)

        var maxDeviation: CGFloat = 0
        for pos in recentPositions {
            let deviation = hypot(pos.x - avgX, pos.y - avgY)
            maxDeviation = max(maxDeviation, deviation)
        }

        return maxDeviation < stablePositionThreshold
    }

    private func handleSubjectNotFound(at time: Date) {
        guard let lastSeen = lastSeenTime else {
            unlock()
            return
        }

        let timeSinceLastSeen = time.timeIntervalSince(lastSeen)

        if timeSinceLastSeen < lostTimeout {
            // Still within grace period - use prediction
            if lockState != .lost {
                transitionTo(.lost)
            }

            // Update predicted position using Kalman filter
            if let subject = trackedSubject {
                let predicted = kalmanFilter.predict()
                let predictedBox = CGRect(
                    x: predicted.x - subject.boundingBox.width / 2,
                    y: predicted.y - subject.boundingBox.height / 2,
                    width: subject.boundingBox.width,
                    height: subject.boundingBox.height
                )

                trackedSubject = TrackedSubject(
                    id: subject.id,
                    boundingBox: subject.boundingBox,
                    predictedBox: predictedBox,
                    confidence: subject.confidence * 0.9,  // Decay confidence
                    animalType: subject.animalType,
                    trackingDuration: subject.trackingDuration
                )
            }
        } else {
            // Lost for too long - give up
            logger.info("Subject lost after \(timeSinceLastSeen)s")
            unlock()
        }
    }

    private func updateFocusPoint() {
        // Update focus point as soon as we have a tracked subject
        // Don't wait for isLocked - start focusing in detecting state too
        // This ensures proper focus for the first auto-shot photo
        guard let subject = trackedSubject, lockState != .idle else {
            focusPoint = nil
            return
        }

        let newFocusPoint = subject.focusPoint

        // Only trigger focus update if point moved significantly
        if let currentFocus = focusPoint {
            let distance = hypot(newFocusPoint.x - currentFocus.x, newFocusPoint.y - currentFocus.y)
            if distance > 0.02 {  // 2% threshold
                focusPoint = newFocusPoint
                onFocusPointUpdate?(newFocusPoint)
            }
        } else {
            focusPoint = newFocusPoint
            onFocusPointUpdate?(newFocusPoint)
        }
    }

    private func transitionTo(_ newState: SubjectLockState) {
        guard newState != lockState else { return }

        let oldState = lockState
        lockState = newState

        // Haptic feedback for state changes
        provideHapticFeedback(from: oldState, to: newState)

        onLockStateChanged?(newState)
    }

    /// Provide haptic feedback for state transitions
    /// Only provide feedback for user-relevant state changes
    private func provideHapticFeedback(from oldState: SubjectLockState, to newState: SubjectLockState) {
        switch (oldState, newState) {
        case (.idle, .tracking), (.idle, .detecting):
            // Started tracking - light tap
            Haptics.light()

        // Note: stable state is internal, no feedback needed
        // Note: lost state feedback removed - box just disappears

        default:
            break
        }
    }
}

// MARK: - Kalman Filter

/// Simple 2D Kalman filter for position smoothing and prediction
/// Tuned for subject tracking with camera movement
/// Parameters adjusted for smooth UI display while maintaining responsiveness
private class KalmanFilter2D {
    private var x: CGFloat = 0  // Position X
    private var y: CGFloat = 0  // Position Y
    private var vx: CGFloat = 0 // Velocity X
    private var vy: CGFloat = 0 // Velocity Y

    private var p: CGFloat = 1.0  // Estimation error
    private let q: CGFloat = 0.12  // Process noise (balanced: smooth but responsive)
    private let r: CGFloat = 0.35  // Measurement noise (balanced: filters jitter but tracks movement)

    private var initialized = false

    func reset() {
        x = 0
        y = 0
        vx = 0
        vy = 0
        p = 1.0
        initialized = false
    }

    func update(measurement: CGPoint) {
        if !initialized {
            x = measurement.x
            y = measurement.y
            initialized = true
            return
        }

        // Predict
        let predictedX = x + vx
        let predictedY = y + vy
        let predictedP = p + q

        // Update
        let k = predictedP / (predictedP + r)  // Kalman gain

        // Update velocity estimate with more weight on recent movement
        vx = 0.7 * vx + 0.3 * (measurement.x - x)
        vy = 0.7 * vy + 0.3 * (measurement.y - y)

        // Update position
        x = predictedX + k * (measurement.x - predictedX)
        y = predictedY + k * (measurement.y - predictedY)
        p = (1 - k) * predictedP
    }

    func predict() -> CGPoint {
        return CGPoint(x: x + vx, y: y + vy)
    }

    func currentPosition() -> CGPoint {
        return CGPoint(x: x, y: y)
    }

    func currentVelocity() -> CGPoint {
        return CGPoint(x: vx, y: vy)
    }
}
