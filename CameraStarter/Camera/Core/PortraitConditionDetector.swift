//
//  PortraitConditionDetector.swift
//  CameraStarter
//
//  Portrait mode condition detector
//  Determines if current scene is suitable for enabling portrait mode
//

import CoreGraphics


/// Portrait mode availability conditions
struct PortraitCondition {
    /// Whether all conditions are satisfied
    let isSatisfied: Bool

    /// Estimated subject distance (meters)
    let estimatedDistance: Float?

    /// Reason for failure (for UI hints)
    let failureReason: String?
}

@MainActor
class PortraitConditionDetector {

    // MARK: - Portrait Condition Thresholds

    /// Minimum distance (meters) - for estimation only, not for condition checking
    private let minDistance: Float = 0.15  // 15cm, allows close-up shots

    /// Maximum distance (meters) - for estimation only, not for condition checking
    private let maxDistance: Float = 1.0

    // MARK: - Distance Estimation Parameters

    /// Calibration factor (based on iPhone 15 Pro main camera empirical value)
    /// This value needs adjustment through actual testing
    private let calibrationFactor: Float = 1.8

    // MARK: - Detection Logic

    /// Detect if Portrait conditions are satisfied
    /// - Parameters:
    ///   - subjectDetections: All detected subjects
    ///   - salientObject: Saliency detection result (for non-subject scenes)
    ///   - currentZoom: Current zoom factor (UI factor, 1x = main camera)
    ///   - hasDepthCapability: Whether current lens supports depth capture
    /// - Returns: Portrait condition result
    func checkConditions(
        subjectDetections: [SubjectDetectionResult],
        salientObject: CGRect?,
        currentZoom: CGFloat,
        hasDepthCapability: Bool
    ) -> PortraitCondition {

        // 1. Check if lens supports depth
        guard hasDepthCapability else {
            return PortraitCondition(
                isSatisfied: false,
                estimatedDistance: nil,
                failureReason: "Switch to 1x or 3x for Portrait"
            )
        }

        // 2. ✨ Only enable Portrait mode when subjects are detected
        // This is a subject photography app, don't enable Portrait for walls, objects, etc.
        if !subjectDetections.isEmpty, let selectedSubject = selectBestSubject(from: subjectDetections) {
            let boundingBox = selectedSubject.boundingBox
            let boxArea = boundingBox.width * boundingBox.height
            let estimatedDistance = estimateDistance(from: boundingBox, zoom: currentZoom)

            // Only exclude extreme cases (too small or too large)
            if boxArea < 0.02 {
                // Subject too small (< 2%), possibly too far or not the subject
                return PortraitCondition(
                    isSatisfied: false,
                    estimatedDistance: nil,
                    failureReason: nil  // Don't show hint, let user naturally move closer
                )
            }
            if boxArea > 0.90 {
                // Subject too large (> 90%), frame almost filled, no background to blur
                return PortraitCondition(
                    isSatisfied: false,
                    estimatedDistance: nil,
                    failureReason: nil  // Don't show hint, let user naturally move back
                )
            }

            // ✅ Subject detected, conditions satisfied
            return PortraitCondition(
                isSatisfied: true,
                estimatedDistance: estimatedDistance,
                failureReason: nil
            )
        }

        // 3. No subjects detected → don't enable Portrait
        return PortraitCondition(
            isSatisfied: false,
            estimatedDistance: nil,
            failureReason: nil
        )
    }

    // MARK: - Private Methods

    /// Select best subject for focus from multiple subjects
    /// Priority: center region > confidence > size
    private func selectBestSubject(from subjects: [SubjectDetectionResult]) -> SubjectDetectionResult? {
        // 1. Filter subjects in center region (30% of frame center)
        let centerRegion = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        let centerSubjects = subjects.filter { subject in
            let subjectCenter = CGPoint(x: subject.boundingBox.midX, y: subject.boundingBox.midY)
            return centerRegion.contains(subjectCenter)
        }

        // 2. If subjects in center region, select highest confidence
        if !centerSubjects.isEmpty {
            return centerSubjects.max(by: { $0.confidence < $1.confidence })
        }

        // 3. Otherwise select largest (closest) subject
        return subjects.max(by: {
            ($0.boundingBox.width * $0.boundingBox.height) <
            ($1.boundingBox.width * $1.boundingBox.height)
        })
    }

    /// Estimate distance based on bounding box size
    /// Formula: distance = calibrationFactor / sqrt(boxArea * zoom)
    private func estimateDistance(from boundingBox: CGRect, zoom: CGFloat) -> Float {
        let boxArea = boundingBox.width * boundingBox.height

        // Avoid division by zero
        guard boxArea > 0.001 else {
            return maxDistance
        }

        // Calculate estimated distance (considering zoom factor)
        let zoomFactor = Float(zoom)
        let distance = calibrationFactor / sqrt(Float(boxArea) * zoomFactor)

        // Limit range
        return min(max(distance, minDistance), maxDistance)
    }
}
