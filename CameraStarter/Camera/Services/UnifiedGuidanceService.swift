//
//  UnifiedGuidanceService.swift
//  CameraStarter
//
//  Unified guidance system for priority-based camera guidance messages
//

import SwiftUI

// MARK: - Unified Guidance State

/// Unified guidance state for camera assistance
enum UnifiedGuidanceState: Equatable {
    /// Searching for subject in frame
    case searching

    /// Need to adjust camera position/angle
    case adjusting

    /// Preparing to capture (focusing, stabilizing)
    case preparing

    /// Ready to capture
    case ready

    var color: Color {
        switch self {
        case .searching:
            return .gray.opacity(0.6)
        case .adjusting:
            return .orange
        case .preparing:
            return .yellow
        case .ready:
            return .green
        }
    }
}

// MARK: - Unified Guidance Message

/// A single guidance message with priority
struct UnifiedGuidanceMessage: Equatable {
    let icon: String
    let textKey: String
    let state: UnifiedGuidanceState
    let priority: Int  // Lower = higher priority

    /// Localized text
    var text: String { textKey.localized }

    // MARK: - P0: No Subject Detected

    static let findSubject = UnifiedGuidanceMessage(
        icon: "pawprint.circle",
        textKey: "guidance.find.subject",
        state: .searching,
        priority: 0
    )

    // MARK: - P1: Angle Adjustment

    static let tiltDown = UnifiedGuidanceMessage(
        icon: "arrow.down.circle.fill",
        textKey: "guidance.tilt.down",
        state: .adjusting,
        priority: 10
    )

    static let tiltUp = UnifiedGuidanceMessage(
        icon: "arrow.up.circle.fill",
        textKey: "guidance.tilt.up",
        state: .adjusting,
        priority: 10
    )

    // MARK: - P1: Distance Adjustment

    static let stepBack = UnifiedGuidanceMessage(
        icon: "arrow.down.backward.circle.fill",
        textKey: "guidance.step.back",
        state: .adjusting,
        priority: 11
    )

    // MARK: - P2: Framing Adjustment

    static let panLeft = UnifiedGuidanceMessage(
        icon: "arrow.left.circle.fill",
        textKey: "guidance.pan.left",
        state: .adjusting,
        priority: 20
    )

    static let panRight = UnifiedGuidanceMessage(
        icon: "arrow.right.circle.fill",
        textKey: "guidance.pan.right",
        state: .adjusting,
        priority: 20
    )

    // MARK: - P2: Focus/Stability

    static let focusing = UnifiedGuidanceMessage(
        icon: "camera.metering.center.weighted",
        textKey: "guidance.focusing",
        state: .preparing,
        priority: 21
    )

    // MARK: - P3: Hold Steady

    static let holdSteady = UnifiedGuidanceMessage(
        icon: "hand.raised.circle.fill",
        textKey: "guidance.hold.steady",
        state: .preparing,
        priority: 30
    )

    // MARK: - P4: Ready States

    static let perfect = UnifiedGuidanceMessage(
        icon: "pawprint.circle.fill",
        textKey: "guidance.perfect",
        state: .ready,
        priority: 40
    )

}

// MARK: - Subject Framing Info

/// Subject framing information extracted from bounding box
struct SubjectFramingInfo {
    let boundingBox: CGRect  // Normalized 0-1 coordinates

    /// Subject area as percentage of frame (0-1)
    var area: CGFloat { boundingBox.width * boundingBox.height }

    /// Subject center X position (0-1)
    var centerX: CGFloat { boundingBox.midX }

    /// Subject center Y position (0-1)
    var centerY: CGFloat { boundingBox.midY }
}

// MARK: - Unified Guidance Input

/// All inputs needed for unified guidance calculation
struct UnifiedGuidanceInput {
    // Device motion
    let tiltState: DeviceTiltState

    // Subject detection
    let subjectDetected: Bool
    let subjectFraming: SubjectFramingInfo?

    // Camera state
    let isFocusReady: Bool
    let isSubjectStable: Bool

    // Front camera flag (tilt guidance is inverted for selfie mode)
    let isFrontCamera: Bool

    init(
        tiltState: DeviceTiltState,
        subjectDetected: Bool,
        subjectFraming: SubjectFramingInfo?,
        isFocusReady: Bool,
        isSubjectStable: Bool,
        isFrontCamera: Bool = false
    ) {
        self.tiltState = tiltState
        self.subjectDetected = subjectDetected
        self.subjectFraming = subjectFraming
        self.isFocusReady = isFocusReady
        self.isSubjectStable = isSubjectStable
        self.isFrontCamera = isFrontCamera
    }
}

// MARK: - Unified Guidance Service

/// Service that provides unified camera guidance
@MainActor
@Observable
final class UnifiedGuidanceService {

    // MARK: - Observable State

    /// Current guidance message
    private(set) var message: UnifiedGuidanceMessage = .findSubject

    // MARK: - Message Stabilization (Anti-jitter)

    /// Pending message waiting for stabilization
    private var pendingMessage: UnifiedGuidanceMessage?

    /// When the pending message started
    private var pendingMessageStartTime: Date?

    /// Minimum time a message must be stable before switching (seconds)
    private let messageStabilizationDuration: TimeInterval = 0.15

    // MARK: - Public Methods

    /// Reset session state
    func reset() {
        message = .findSubject
        pendingMessage = nil
        pendingMessageStartTime = nil
    }

    /// Update guidance based on current input
    func update(with input: UnifiedGuidanceInput) {
        let newMessage = calculateGuidance(input)
        updateMessageWithStabilization(newMessage)
    }

    /// Update message with stabilization (anti-jitter)
    private func updateMessageWithStabilization(_ newMessage: UnifiedGuidanceMessage) {
        // If same as current message, clear pending and return
        if newMessage == message {
            pendingMessage = nil
            pendingMessageStartTime = nil
            return
        }

        // Allow immediate transition to "perfect" (ready to capture)
        if newMessage == .perfect {
            message = newMessage
            pendingMessage = nil
            pendingMessageStartTime = nil
            return
        }

        // For other transitions, require stabilization
        if newMessage != pendingMessage {
            pendingMessage = newMessage
            pendingMessageStartTime = Date()
        } else if let startTime = pendingMessageStartTime,
                  Date().timeIntervalSince(startTime) >= messageStabilizationDuration {
            message = newMessage
            pendingMessage = nil
            pendingMessageStartTime = nil
        }
    }

    // MARK: - Private Methods

    private func calculateGuidance(_ input: UnifiedGuidanceInput) -> UnifiedGuidanceMessage {
        // P0: Must have subject detected
        guard input.subjectDetected else {
            return .findSubject
        }

        // P1: Check device angle (tilt)
        // For front camera (selfie mode), tilt guidance is inverted because
        // the user sees themselves mirrored - tilting the phone down means
        // shooting from below (user's perspective), not above
        switch input.tiltState {
        case .tiltingDown:
            // Rear camera: phone tilting down = shooting from above → tell user to tilt up
            // Front camera: phone tilting down = shooting from below (mirrored) → tell user to tilt down
            return input.isFrontCamera ? .tiltDown : .tiltUp
        case .tiltingUp:
            // Rear camera: phone tilting up = shooting from below → tell user to tilt down
            // Front camera: phone tilting up = shooting from above (mirrored) → tell user to tilt up
            return input.isFrontCamera ? .tiltUp : .tiltDown
        case .upright:
            break  // Good angle, continue checking other conditions
        }

        // P1: Check distance (step back if subject is too large in frame)
        if let framing = input.subjectFraming {
            // If subject takes up more than 70% of frame, suggest stepping back
            if framing.area > 0.7 {
                return .stepBack
            }
        }

        // P2: Check framing (pan left/right if subject is off-center)
        if let framing = input.subjectFraming {
            let centerX = framing.centerX
            // If subject is significantly off-center horizontally
            if centerX < 0.3 {
                return .panLeft   // Subject is on left, move phone left to center subject
            } else if centerX > 0.7 {
                return .panRight  // Subject is on right, move phone right to center subject
            }
        }

        // P2: Check focus
        if !input.isFocusReady {
            return .focusing
        }

        // P3: Check stability
        if !input.isSubjectStable {
            return .holdSteady
        }

        // All conditions met - ready to capture!
        return .perfect
    }

}
