//
//  DeviceMotionManager.swift
//  CameraStarter
//
//  Device motion sensor manager
//  Uses CoreMotion to detect phone tilt angle for camera angle guidance
//
//  Optimization references:
//  - Professional camera apps use 30-60Hz update frequency
//  - Low-pass filter smooths sensor noise
//  - Hysteresis threshold prevents frequent state switching
//

import CoreMotion
import Foundation
import UIKit
import os.log

/// Phone tilt state
enum DeviceTiltState: Equatable {
    case upright         // Vertical (normal photo posture)
    case tiltingDown     // Tilting down (shooting from above)
    case tiltingUp       // Tilting up (shooting from below)

    /// Calculate tilt state based on device attitude and current screen orientation (with hysteresis threshold)
    /// - Parameters:
    ///   - pitch: pitch angle (radians)
    ///   - roll: roll angle (radians)
    ///   - deviceOrientation: Current device physical orientation
    ///   - currentState: Current state (for hysteresis judgment)
    init(pitch: Double, roll: Double, deviceOrientation: UIDeviceOrientation, currentState: DeviceTiltState? = nil) {
        let pitchDegrees = pitch * 180.0 / .pi
        let rollDegrees = roll * 180.0 / .pi

        // Adjust judgment logic based on device orientation
        // CoreMotion coordinate system is fixed, but physical meaning of pitch/roll changes with device orientation
        switch deviceOrientation {
        case .portrait:
            // Portrait mode: use original logic
            self = Self.calculateForPortrait(pitch: pitchDegrees, roll: rollDegrees, currentState: currentState)

        case .landscapeLeft:
            // Landscape left (Home button on right): original roll becomes new "pitch"
            // In this orientation, user tilting up/down corresponds to roll changes in original coordinate system
            self = Self.calculateForLandscapeLeft(pitch: pitchDegrees, roll: rollDegrees, currentState: currentState)

        case .landscapeRight:
            // Landscape right (Home button on left): original roll becomes new "pitch" (opposite direction)
            self = Self.calculateForLandscapeRight(pitch: pitchDegrees, roll: rollDegrees, currentState: currentState)

        case .portraitUpsideDown:
            // Portrait upside down: pitch/roll directions are both reversed
            self = Self.calculateForPortraitUpsideDown(pitch: pitchDegrees, roll: rollDegrees, currentState: currentState)

        default:
            // Unknown orientation or face up/down, default to portrait logic
            self = Self.calculateForPortrait(pitch: pitchDegrees, roll: rollDegrees, currentState: currentState)
        }
    }

    // MARK: - Threshold Configuration

    /// Pitch range considered "upright" (degrees)
    /// 70-100° covers natural phone holding positions (wider range = less sensitive)
    private static let uprightRange: ClosedRange<Double> = 70...100

    /// Roll threshold for distinguishing tilt up vs down (degrees)
    /// |roll| > 130° indicates phone is tilting up (camera pointing upward)
    private static let rollThresholdForTiltUp: Double = 130

    // MARK: - Direction-specific Calculation Logic

    /// Portrait mode judgment logic
    private static func calculateForPortrait(pitch: Double, roll: Double, currentState: DeviceTiltState?) -> DeviceTiltState {
        let absRoll = abs(roll)

        // Check if pitch is in upright range
        if uprightRange.contains(pitch) {
            return .upright
        }

        // Not in upright range, determine if tilting up or down
        if pitch < uprightRange.lowerBound {
            // pitch too small - phone tilting forward
            // Use roll to distinguish: high roll means tilting up (camera pointing up)
            if absRoll > rollThresholdForTiltUp {
                return .tiltingUp
            } else {
                return .tiltingDown
            }
        }

        // pitch > uprightRange.upperBound (phone tilted back excessively)
        return .tiltingUp
    }

    /// Landscape left (Home button on right) judgment logic
    private static func calculateForLandscapeLeft(pitch: Double, roll: Double, currentState: DeviceTiltState?) -> DeviceTiltState {
        // In landscape left mode:
        // - Camera level: roll ≈ -90°
        // - Tilting down (shooting from above): roll > -78° (toward 0°)
        // - Tilting up (shooting from below): roll < -102° (toward -180°)

        let isCurrentlyUpright = currentState == .upright
        let enterRange: ClosedRange<Double> = -100...(-80)
        let exitRange: ClosedRange<Double> = -106...(-74)

        if isCurrentlyUpright {
            if exitRange.contains(roll) {
                return .upright
            }
        } else {
            if enterRange.contains(roll) {
                return .upright
            }
        }

        if roll > enterRange.upperBound {
            return .tiltingDown
        } else {
            return .tiltingUp
        }
    }

    /// Landscape right (Home button on left) judgment logic
    private static func calculateForLandscapeRight(pitch: Double, roll: Double, currentState: DeviceTiltState?) -> DeviceTiltState {
        // In landscape right mode:
        // - Camera level: roll ≈ 90°
        // - Tilting down (shooting from above): roll < 78° (toward 0°)
        // - Tilting up (shooting from below): roll > 102° (toward 180°)

        let isCurrentlyUpright = currentState == .upright
        let enterRange: ClosedRange<Double> = 80...100
        let exitRange: ClosedRange<Double> = 74...106

        if isCurrentlyUpright {
            if exitRange.contains(roll) {
                return .upright
            }
        } else {
            if enterRange.contains(roll) {
                return .upright
            }
        }

        if roll < enterRange.lowerBound {
            return .tiltingDown
        } else {
            return .tiltingUp
        }
    }

    /// Portrait upside down judgment logic
    private static func calculateForPortraitUpsideDown(pitch: Double, roll: Double, currentState: DeviceTiltState?) -> DeviceTiltState {
        // Portrait upside down: pitch and roll directions are both reversed
        let absRoll = abs(roll)
        let isCurrentlyUpright = currentState == .upright
        let enterRange: ClosedRange<Double> = -100...(-70)
        let exitRange: ClosedRange<Double> = -112...(-58)

        if isCurrentlyUpright {
            if exitRange.contains(pitch) {
                return .upright
            }
        } else {
            if enterRange.contains(pitch) {
                return .upright
            }
        }

        if pitch > enterRange.upperBound {
            if absRoll > rollThresholdForTiltUp {
                return .tiltingDown
            } else {
                return .tiltingUp
            }
        }

        return .upright
    }

    var isUpright: Bool {
        self == .upright
    }
}

/// Device motion manager
@Observable
@MainActor
final class DeviceMotionManager {

    static let shared = DeviceMotionManager()

    // CoreMotion manager
    private let motionManager = CMMotionManager()

    // MARK: - Raw Angles (Radians)

    /// Current pitch angle (radians), with low-pass filtering
    /// Range: [-π, +π], approximately π/2 (90°) when shooting vertically
    private(set) var pitch: Double = 0.0

    /// Current roll angle (radians), with low-pass filtering
    /// Range: [-π, +π], jumps to ±π (±180°) when tilting up
    private(set) var roll: Double = 0.0

    // MARK: - Processed Angles (Degrees) - For UI Display

    /// Offset from ideal shooting angle (degrees)
    /// Positive = tilting down, negative = tilting up
    /// Range: approximately -60° to +60°
    private(set) var tiltOffsetDegrees: Double = 0.0

    /// Horizontal tilt angle (degrees) - for Level Indicator
    /// Positive = tilting right, negative = tilting left
    /// Range: -180° to +180°
    private(set) var horizontalTiltDegrees: Double = 0.0

    // MARK: - State

    /// Current tilt state (initially tiltingDown, requires strict threshold to enter upright)
    private(set) var tiltState: DeviceTiltState = .tiltingDown

    /// Whether in "level" state (for haptic feedback)
    private(set) var isLevel: Bool = false

    /// Current device physical orientation (passed from CameraView)
    var currentDeviceOrientation: UIDeviceOrientation = .portrait

    /// Whether currently monitoring
    private(set) var isMonitoring = false

    /// Update counter for triggering SwiftUI onChange (incremented on each motion update)
    private(set) var updateTrigger: UInt64 = 0

    // MARK: - Configuration

    /// Update frequency: 15Hz (sufficient for tilt guidance, half the CPU of 30Hz)
    private let updateInterval: TimeInterval = 1.0 / 15.0

    /// Low-pass filter coefficient (0-1, larger = faster response but more jitter)
    /// 0.3 = smoother; 0.5 = medium; 0.7 = fast response; 1.0 = no filtering
    private let lowPassFilterAlpha: Double = 0.5

    /// State stabilization duration (seconds) - longer duration = less sensitive to brief movements
    private let stateStabilizationDuration: TimeInterval = 0.25

    /// Level judgment threshold (degrees) - considered "level" within this range
    private let levelThreshold: Double = 2.0

    // MARK: - Internal State

    private var filteredPitch: Double = 0.0
    private var filteredRoll: Double = 0.0
    private var isFilterInitialized: Bool = false  // Whether filter is initialized
    private var pendingTiltState: DeviceTiltState?
    private var pendingStateStartTime: Date?

    private let logger = Logger(subsystem: Log.subsystem, category: "DeviceMotionManager")

    // MARK: - Initialization

    private init() {
        guard motionManager.isDeviceMotionAvailable else {
            logger.warning("Device motion not available on this device")
            return
        }
    }

    // MARK: - Public Methods

    /// Start monitoring device motion
    func startMonitoring() {
        guard !isMonitoring else {
            return
        }

        guard motionManager.isDeviceMotionAvailable else {
            logger.error("Cannot start monitoring: device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = updateInterval

        // Use main thread queue to update UI
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self = self else { return }

            if let error = error {
                self.logger.error("Device motion update error: \(error.localizedDescription)")
                return
            }

            guard let motion = motion else { return }
            self.processMotionData(motion)
        }

        isMonitoring = true
    }

    /// Stop monitoring device motion
    func stopMonitoring() {
        guard isMonitoring else { return }

        motionManager.stopDeviceMotionUpdates()
        isMonitoring = false
        isFilterInitialized = false  // Reset filter, reinitialize on next start
    }

    /// Get current pitch angle (degrees)
    var pitchDegrees: Double {
        pitch * 180.0 / .pi
    }

    /// Get current roll angle (degrees)
    var rollDegrees: Double {
        roll * 180.0 / .pi
    }

    // MARK: - Private Methods

    /// Process motion data (low-pass filtering + state calculation)
    private func processMotionData(_ motion: CMDeviceMotion) {
        let rawPitch = motion.attitude.pitch
        let rawRoll = motion.attitude.roll

        // On first data reception, initialize filter directly (avoid smoothing from 0)
        if !isFilterInitialized {
            filteredPitch = rawPitch
            filteredRoll = rawRoll
            isFilterInitialized = true
        } else {
            // Low-pass filter: smoothed = alpha * new + (1 - alpha) * old
            filteredPitch = lowPassFilterAlpha * rawPitch + (1 - lowPassFilterAlpha) * filteredPitch
            filteredRoll = lowPassFilterAlpha * rawRoll + (1 - lowPassFilterAlpha) * filteredRoll
        }

        // Update published angle values
        pitch = filteredPitch
        roll = filteredRoll

        // Calculate offset from ideal angle (for UI)
        let oldTiltOffset = tiltOffsetDegrees
        calculateTiltOffset()

        // Calculate horizontal tilt (for Level Indicator)
        let oldHorizontalTilt = horizontalTiltDegrees
        calculateHorizontalTilt()

        // Calculate tilt state (with hysteresis threshold)
        let oldTiltState = tiltState
        let newTiltState = DeviceTiltState(
            pitch: filteredPitch,
            roll: filteredRoll,
            deviceOrientation: currentDeviceOrientation,
            currentState: tiltState
        )

        updateTiltState(newTiltState)

        // Check if "level" state is achieved (for haptic feedback)
        let oldIsLevel = isLevel
        checkLevelState()

        // Only notify SwiftUI observers when something meaningful changed
        // This avoids 15 unnecessary re-renders per second when device is still
        let tiltOffsetChanged = abs(tiltOffsetDegrees - oldTiltOffset) > 0.5  // > 0.5° change
        let horizontalChanged = abs(horizontalTiltDegrees - oldHorizontalTilt) > 0.5
        let stateChanged = tiltState != oldTiltState
        let levelChanged = isLevel != oldIsLevel

        if tiltOffsetChanged || horizontalChanged || stateChanged || levelChanged {
            updateTrigger &+= 1
        }
    }

    /// Calculate offset from ideal shooting angle
    private func calculateTiltOffset() {
        let pitchDeg = filteredPitch * 180.0 / .pi
        let rollDeg = filteredRoll * 180.0 / .pi
        let absRoll = abs(rollDeg)

        // Ideal angle: pitch ≈ 85° in portrait mode
        let idealPitch: Double

        switch currentDeviceOrientation {
        case .portrait, .portraitUpsideDown:
            idealPitch = 85.0
        case .landscapeLeft:
            // Landscape left: ideal roll ≈ -90°
            tiltOffsetDegrees = -(rollDeg + 90.0)  // Negative sign makes positive = shooting from above
            return
        case .landscapeRight:
            // Landscape right: ideal roll ≈ 90°
            tiltOffsetDegrees = rollDeg - 90.0
            return
        default:
            idealPitch = 85.0
        }

        // Portrait mode: calculate pitch offset
        // Consider roll flip (when tilting up, roll jumps to ±180°)
        if absRoll > 130 {
            // Tilting up
            tiltOffsetDegrees = -(180.0 - pitchDeg)  // Negative indicates upward
        } else {
            // Normal or tilting down
            tiltOffsetDegrees = idealPitch - pitchDeg
        }

        // Limit range
        tiltOffsetDegrees = max(-60, min(60, tiltOffsetDegrees))
    }

    /// Calculate horizontal tilt angle (for Level Indicator)
    private func calculateHorizontalTilt() {
        // Use gravity vector for more accurate horizontal tilt calculation
        // Simplified here using roll, but requires special handling in portrait mode
        let rollDeg = filteredRoll * 180.0 / .pi

        switch currentDeviceOrientation {
        case .portrait:
            // Portrait: roll directly represents left/right tilt (when pitch ≈ 90°)
            horizontalTiltDegrees = rollDeg
        case .landscapeLeft:
            // Landscape left: pitch represents left/right tilt
            horizontalTiltDegrees = filteredPitch * 180.0 / .pi
        case .landscapeRight:
            // Landscape right: pitch represents left/right tilt (reversed)
            horizontalTiltDegrees = -(filteredPitch * 180.0 / .pi)
        default:
            horizontalTiltDegrees = rollDeg
        }
    }

    /// Update tilt state (with debouncing)
    private func updateTiltState(_ newTiltState: DeviceTiltState) {
        if newTiltState != tiltState {
            if newTiltState != pendingTiltState {
                pendingTiltState = newTiltState
                pendingStateStartTime = Date()
            } else if let startTime = pendingStateStartTime,
                      Date().timeIntervalSince(startTime) >= stateStabilizationDuration {
                // State stable, execute switch
                tiltState = newTiltState
                pendingTiltState = nil
                pendingStateStartTime = nil

            }
        } else {
            pendingTiltState = nil
            pendingStateStartTime = nil
        }
    }

    /// Check if level state is achieved
    private func checkLevelState() {
        let isCurrentlyLevel = abs(tiltOffsetDegrees) <= levelThreshold && tiltState == .upright
        isLevel = isCurrentlyLevel
    }
}
