//
//  SubjectDetector.swift
//  CameraStarter
//
//  Finds what the camera should focus on. Each full pass looks for animals
//  with Vision's animal recognizer and falls back to the most salient region
//  when there are none; between passes, VNTrackObjectRequest follows the
//  subjects already found. Drives auto-focus and subject tracking.
//

import AVFoundation
import Vision
import CoreImage
import CoreVideo
import os.log

/// Detection throttler - uses actor to ensure thread safety
actor DetectionThrottler {
    private var lastDetectionTime: Date = .distantPast
    private var currentInterval: TimeInterval = 0.05
    private var noSubjectCount: Int = 0

    /// Check if current frame should be processed
    func shouldProcess() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= currentInterval else {
            return false
        }
        lastDetectionTime = now
        return true
    }

    /// Update detection interval (based on whether subject is detected)
    func updateInterval(
        hasSubject: Bool,
        fastInterval: TimeInterval,
        normalInterval: TimeInterval,
        slowInterval: TimeInterval
    ) {
        if hasSubject {
            currentInterval = fastInterval
            noSubjectCount = 0
        } else {
            noSubjectCount += 1
            // Ramp down quickly: each detection frame without subject costs ~30ms
            if noSubjectCount > 5 {
                currentInterval = slowInterval
            } else if noSubjectCount > 1 {
                currentInterval = normalInterval
            }
        }
    }
}

/// Eye detection result
struct EyeDetection: Equatable, Sendable {
    let position: CGPoint  // Normalized coordinates (0-1)
    let type: String       // "Left eye" or "Right eye"

    /// Check if eye position is within bounding box (sanity check)
    func isWithin(_ boundingBox: CGRect) -> Bool {
        return boundingBox.contains(position)
    }
}

/// Subject detection result
struct SubjectDetectionResult: Equatable, Sendable, Identifiable {
    let id: UUID  // Stable unique identifier (for UI tracking)
    let boundingBox: CGRect  // Subject bounding box (normalized coordinates 0-1)
    let headBoundingBox: CGRect?  // Head bounding box (if head is detected)
    let confidence: Float    // Confidence score
    let animalType: String   // "cat" or "dog"
    let eyes: [EyeDetection]  // 👀 Detected eyes (may be 0, 1, or 2)

    /// Convenience initializer (auto-generates ID)
    init(boundingBox: CGRect, headBoundingBox: CGRect? = nil, confidence: Float, animalType: String, eyes: [EyeDetection] = [], id: UUID = UUID()) {
        self.id = id
        self.boundingBox = boundingBox
        self.headBoundingBox = headBoundingBox
        self.confidence = confidence
        self.animalType = animalType
        self.eyes = eyes
    }

    /// Display bounding box (prioritize head, fallback to full body)
    /// Add sanity check: head box must be within full body box
    var displayBoundingBox: CGRect {
        guard let headBox = headBoundingBox else {
            return boundingBox
        }

        // Check if head box is mostly within full body box (at least 70% overlap)
        let intersection = boundingBox.intersection(headBox)
        let headArea = headBox.width * headBox.height
        let intersectionArea = intersection.width * intersection.height

        if headArea > 0 && intersectionArea / headArea > 0.7 {
            return headBox  // Head box is valid, use head box
        } else {
            return boundingBox  // Head box is invalid, use full body box
        }
    }
}

/// Vision detection output (for main thread use)
private struct VisionDetectionOutput: Sendable {
    let subjectDetections: [SubjectDetectionResult]
    let bestSubject: SubjectDetectionResult?
    let focusCandidate: CGPoint?
    let salientObjectBoundingBox: CGRect?
    let isTrackingFrame: Bool  // true = lightweight tracking, false = full detection
}

/// Safely pass CVPixelBuffer across actors
private struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

// CVPixelBuffer is not marked Sendable, but is used read-only across actors here
extension CVPixelBuffer: @unchecked @retroactive Sendable {}

/// State for a single tracked subject (used between full detection cycles)
private struct TrackedSubjectState {
    let id: UUID
    var trackRequest: VNTrackObjectRequest
    var lastTrackingConfidence: Float
    // Cached metadata from last full detection
    var cachedAnimalType: String
    var cachedConfidence: Float
    var cachedHeadBoundingBox: CGRect?
    var cachedEyes: [EyeDetection]
}

/// Vision pipeline (isolates Vision requests and throttling logic)
private actor VisionPipeline {
    private let logger = Logger(subsystem: Log.subsystem, category: "VisionPipeline")

    /// Model preload status
    private var modelsReady: Bool = false

    // Vision requests
    private let saliencyRequest: VNGenerateAttentionBasedSaliencyImageRequest = {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        return request
    }()

    private let animalRequest: VNRecognizeAnimalsRequest = {
        let request = VNRecognizeAnimalsRequest()
        return request
    }()

    private let animalPoseRequest: VNDetectAnimalBodyPoseRequest = {
        let request = VNDetectAnimalBodyPoseRequest()
        return request
    }()

    // Throttler
    private let throttler = DetectionThrottler()

    private let minConfidenceThreshold: Float
    private let minSubjectConfidenceThreshold: Float

    // MARK: - Tracking State

    /// Stateful sequence handler for VNTrackObjectRequest (reused across frames)
    private var sequenceHandler: VNSequenceRequestHandler = VNSequenceRequestHandler()

    /// One tracker per detected subject
    private var trackedSubjects: [TrackedSubjectState] = []

    /// Frames since last full detection
    private var framesSinceLastDetection: Int = 0

    /// How often to run full re-detection (every N tracking frames)
    private let redetectionInterval: Int = 30

    /// Minimum tracking confidence before triggering re-detection
    private let trackingConfidenceThreshold: Float = 0.3

    /// Debug counters
    private(set) var trackingFrameCount: Int = 0
    private(set) var detectionFrameCount: Int = 0

    init(minConfidenceThreshold: Float, minSubjectConfidenceThreshold: Float) {
        self.minConfidenceThreshold = minConfidenceThreshold
        self.minSubjectConfidenceThreshold = minSubjectConfidenceThreshold
    }

    /// Preload Vision models
    func preloadModels() async {
        // If already preloaded, return immediately
        guard !modelsReady else { return }

        let dummyImage = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let cgImage = CIContext().createCGImage(dummyImage, from: dummyImage.extent) else { return }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([saliencyRequest, animalRequest, animalPoseRequest])
            modelsReady = true
        } catch {
            logger.warning("⚠️ Failed to preload Vision models: \(error.localizedDescription)")
        }
    }

    /// Process a frame: either lightweight tracking or full detection
    func processFrame(
        pixelBufferBox: PixelBufferBox,
        isFrontCamera: Bool,
        fastInterval: TimeInterval,
        normalInterval: TimeInterval,
        slowInterval: TimeInterval,
        skipPoseDetection: Bool = false
    ) async -> VisionDetectionOutput? {
        // 🔑 Ensure models are preloaded (will wait on first call)
        if !modelsReady {
            await preloadModels()
        }

        let shouldProcess = await throttler.shouldProcess()
        guard shouldProcess else {
            return nil
        }

        // Front camera video is mirrored, so we need different orientation
        let orientation: CGImagePropertyOrientation = isFrontCamera ? .leftMirrored : .right

        if shouldRunFullDetection() {
            detectionFrameCount += 1
            let result = await runFullDetection(
                pixelBufferBox: pixelBufferBox,
                orientation: orientation,
                fastInterval: fastInterval,
                normalInterval: normalInterval,
                slowInterval: slowInterval,
                skipPoseDetection: skipPoseDetection
            )
            return result
        } else {
            trackingFrameCount += 1
            let result = await runTracking(
                pixelBufferBox: pixelBufferBox,
                orientation: orientation,
                fastInterval: fastInterval,
                normalInterval: normalInterval,
                slowInterval: slowInterval
            )
            return result
        }
    }

    // MARK: - Detect-Then-Track Core

    /// Determine whether full ML detection is needed
    private func shouldRunFullDetection() -> Bool {
        // No trackers → must detect
        if trackedSubjects.isEmpty { return true }

        // Periodic re-detection
        if framesSinceLastDetection >= redetectionInterval { return true }

        // Any tracker's confidence dropped too low
        for subject in trackedSubjects {
            if subject.lastTrackingConfidence < trackingConfidenceThreshold {
                return true
            }
        }

        return false
    }

    /// Full ML detection (expensive: VNRecognizeAnimalsRequest + optional pose + saliency)
    private func runFullDetection(
        pixelBufferBox: PixelBufferBox,
        orientation: CGImagePropertyOrientation,
        fastInterval: TimeInterval,
        normalInterval: TimeInterval,
        slowInterval: TimeInterval,
        skipPoseDetection: Bool
    ) async -> VisionDetectionOutput? {
        let imageRequestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBufferBox.buffer,
            orientation: orientation,
            options: [:]
        )

        do {
            // 1) Run subject recognition
            try imageRequestHandler.perform([animalRequest])
            let animalResults = animalRequest.results ?? []

            // 2) Only run pose detection when subjects are detected and not in power saving
            var poseResults: [VNAnimalBodyPoseObservation] = []
            if !animalResults.isEmpty && !skipPoseDetection {
                try imageRequestHandler.perform([animalPoseRequest])
                poseResults = animalPoseRequest.results ?? []
            }

            // 3) Only run saliency when no subjects detected, as focus fallback
            var salientObjects: [VNDetectedObjectObservation] = []
            if animalResults.isEmpty {
                try imageRequestHandler.perform([saliencyRequest])
                if let saliencyResult = saliencyRequest.results?.first,
                   let objects = saliencyResult.salientObjects {
                    salientObjects = objects
                }
            }

            // Build subject detections
            var allSubjectDetections: [SubjectDetectionResult] = []

            if !animalResults.isEmpty {
                for (index, animal) in animalResults.enumerated() {
                    guard animal.confidence > minSubjectConfidenceThreshold else { continue }

                    let animalType = animal.labels.first?.identifier ?? "unknown"
                    let matchingPose = index < poseResults.count ? poseResults[index] : nil
                    let allEyes = extractEyes(from: matchingPose)
                    let headBox = extractHeadBoundingBox(from: matchingPose)
                    let validEyes = allEyes.filter { animal.boundingBox.contains($0.position) }

                    await allSubjectDetections.append(SubjectDetectionResult(
                        boundingBox: animal.boundingBox,
                        headBoundingBox: headBox,
                        confidence: animal.confidence,
                        animalType: animalType,
                        eyes: validEyes
                    ))
                }
            }

            // Initialize trackers from fresh detection results
            await initializeTrackers(from: animalResults, subjectDetections: allSubjectDetections)

            // Select best subject for focus
            let subjectDetectionResult = selectBestSubjectForFocus(from: allSubjectDetections)

            // Determine focus point
            var focusCenter: CGPoint? = nil
            if let subjectResult = subjectDetectionResult {
                focusCenter = getBestFocusPoint(eyes: subjectResult.eyes, boundingBox: subjectResult.boundingBox)
            } else if let mostSalient = salientObjects.max(by: { $0.confidence < $1.confidence }),
                      mostSalient.confidence > minConfidenceThreshold {
                focusCenter = CGPoint(x: mostSalient.boundingBox.midX, y: mostSalient.boundingBox.midY)
            }

            // Saliency box for portrait
            var salientObjectBox: CGRect? = nil
            if let mostSalient = salientObjects.max(by: { $0.confidence < $1.confidence }),
               mostSalient.confidence > minConfidenceThreshold {
                salientObjectBox = mostSalient.boundingBox
            }

            // Update throttler — only subjects count as "subject" for frequency control
            // Saliency fallback should NOT keep detection at high frequency
            await throttler.updateInterval(
                hasSubject: !allSubjectDetections.isEmpty,
                fastInterval: fastInterval,
                normalInterval: normalInterval,
                slowInterval: slowInterval
            )

            return VisionDetectionOutput(
                subjectDetections: allSubjectDetections,
                bestSubject: subjectDetectionResult,
                focusCandidate: focusCenter,
                salientObjectBoundingBox: salientObjectBox,
                isTrackingFrame: false
            )
        } catch {
            logger.error("Vision detection error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Lightweight tracking using VNTrackObjectRequest (~2-5ms CPU vs ~50-100ms ANE)
    private func runTracking(
        pixelBufferBox: PixelBufferBox,
        orientation: CGImagePropertyOrientation,
        fastInterval: TimeInterval,
        normalInterval: TimeInterval,
        slowInterval: TimeInterval
    ) async -> VisionDetectionOutput? {
        framesSinceLastDetection += 1

        var updatedSubjects: [TrackedSubjectState] = []
        var allSubjectDetections: [SubjectDetectionResult] = []

        for var subject in trackedSubjects {
            do {
                // Run lightweight tracking via stateful sequence handler
                try await sequenceHandler.perform(
                    [subject.trackRequest],
                    on: pixelBufferBox.buffer,
                    orientation: orientation
                )

                // Get updated observation
                guard let updatedObservation = await subject.trackRequest.results?.first as? VNDetectedObjectObservation,
                      updatedObservation.confidence > VNConfidence(trackingConfidenceThreshold) else {
                    // Tracker lost this subject — will trigger re-detection next frame
                    continue
                }

                // Create new track request for next frame using the updated observation (MainActor-isolated API)
                await MainActor.run {
                    let newTrackRequest = VNTrackObjectRequest(detectedObjectObservation: updatedObservation)
                    newTrackRequest.trackingLevel = .fast
                    subject.trackRequest = newTrackRequest
                }
                subject.lastTrackingConfidence = Float(updatedObservation.confidence)

                updatedSubjects.append(subject)

                // Build SubjectDetectionResult from tracking + cached metadata
                // Blend confidence: cached detection confidence × tracking confidence
                let blendedConfidence = subject.cachedConfidence * Float(updatedObservation.confidence)

                await allSubjectDetections.append(SubjectDetectionResult(
                    boundingBox: updatedObservation.boundingBox,
                    headBoundingBox: nil,  // No head box during tracking (pose not run)
                    confidence: blendedConfidence,
                    animalType: subject.cachedAnimalType,
                    eyes: [],  // No eyes during tracking (pose not run)
                    id: subject.id
                ))
            } catch {
                logger.warning("⚠️ Tracking failed for subject \(subject.id): \(error.localizedDescription)")
                // Tracker failed — will trigger re-detection
            }
        }

        trackedSubjects = updatedSubjects

        // If all trackers lost, force re-detection on next frame
        if trackedSubjects.isEmpty {
            return nil
        }

        // Select best subject for focus
        let subjectDetectionResult = selectBestSubjectForFocus(from: allSubjectDetections)

        // Focus uses bounding box center during tracking (no eyes available)
        var focusCenter: CGPoint? = nil
        if let subjectResult = subjectDetectionResult {
            focusCenter = CGPoint(x: subjectResult.boundingBox.midX, y: subjectResult.boundingBox.midY)
        }

        // Update throttler
        await throttler.updateInterval(
            hasSubject: focusCenter != nil,
            fastInterval: fastInterval,
            normalInterval: normalInterval,
            slowInterval: slowInterval
        )

        return VisionDetectionOutput(
            subjectDetections: allSubjectDetections,
            bestSubject: subjectDetectionResult,
            focusCandidate: focusCenter,
            salientObjectBoundingBox: nil,  // No saliency during tracking
            isTrackingFrame: true
        )
    }

    /// Initialize trackers from fresh detection results
    private func initializeTrackers(from animalResults: [VNRecognizedObjectObservation], subjectDetections: [SubjectDetectionResult]) async {
        // Reset tracking state
        trackedSubjects = []
        framesSinceLastDetection = 0
        // Recreate sequence handler to prevent unbounded memory growth
        sequenceHandler = VNSequenceRequestHandler()

        for (index, animal) in animalResults.enumerated() {
            guard animal.confidence > minSubjectConfidenceThreshold else { continue }
            guard index < subjectDetections.count else { break }

            let subject = subjectDetections[index]

            // Create initial track request on MainActor (Vision request types are MainActor-isolated)
            let trackRequest: VNTrackObjectRequest = await MainActor.run {
                let req = VNTrackObjectRequest(detectedObjectObservation: animal)
                req.trackingLevel = .fast
                return req
            }

            trackedSubjects.append(TrackedSubjectState(
                id: subject.id,
                trackRequest: trackRequest,
                lastTrackingConfidence: Float(animal.confidence),
                cachedAnimalType: subject.animalType,
                cachedConfidence: animal.confidence,
                cachedHeadBoundingBox: subject.headBoundingBox,
                cachedEyes: subject.eyes
            ))
        }
    }

    /// Reset all tracking state (called on camera switch, stop, etc.)
    func resetTracking() {
        trackedSubjects = []
        framesSinceLastDetection = 0
        sequenceHandler = VNSequenceRequestHandler()
    }

    // MARK: - Pose Position Extraction

    /// Extract all detected eyes from animal pose
    /// Returns: Array of detected eyes (may be 0, 1, or 2)
    private func extractEyes(from pose: VNAnimalBodyPoseObservation?) -> [EyeDetection] {
        var eyes: [EyeDetection] = []

        guard let pose = pose else { return eyes }

        // Try to get left eye
        if let leftEye = try? pose.recognizedPoint(.leftEye),
           leftEye.confidence > 0.3 {
            eyes.append(EyeDetection(position: leftEye.location, type: "Left eye"))
        }

        // Try to get right eye
        if let rightEye = try? pose.recognizedPoint(.rightEye),
           rightEye.confidence > 0.3 {
            eyes.append(EyeDetection(position: rightEye.location, type: "Right eye"))
        }

        return eyes
    }

    /// Extract head bounding box from animal pose
    /// Based on eye and nose positions, with appropriate padding
    private func extractHeadBoundingBox(from pose: VNAnimalBodyPoseObservation?) -> CGRect? {
        guard let pose = pose else { return nil }

        let headPoints = getHeadPoints(from: pose)
        guard headPoints.count >= 2 else { return nil }  // Need at least 2 points to form bounding box

        // Calculate bounds of head key points (use safe binding to prevent crashes from empty arrays)
        guard
            let minX = headPoints.map(\.x).min(),
            let maxX = headPoints.map(\.x).max(),
            let minY = headPoints.map(\.y).min(),
            let maxY = headPoints.map(\.y).max()
        else { return nil }

        // Add padding (expand head boundary by 50%)
        let width = maxX - minX
        let height = maxY - minY
        let paddingX = max(width * 0.5, 0.05)  // At least 5% padding
        let paddingY = max(height * 0.5, 0.05)

        return CGRect(
            x: max(0, minX - paddingX),
            y: max(0, minY - paddingY),
            width: min(1, width + paddingX * 2),
            height: min(1, height + paddingY * 2)
        )
    }

    /// Get head key points
    private func getHeadPoints(from pose: VNAnimalBodyPoseObservation) -> [CGPoint] {
        var headPoints: [CGPoint] = []
        let minConfidence: Float = 0.3

        if let leftEye = try? pose.recognizedPoint(.leftEye), leftEye.confidence > minConfidence {
            headPoints.append(leftEye.location)
        }
        if let rightEye = try? pose.recognizedPoint(.rightEye), rightEye.confidence > minConfidence {
            headPoints.append(rightEye.location)
        }
        if let nose = try? pose.recognizedPoint(.nose), nose.confidence > minConfidence {
            headPoints.append(nose.location)
        }

        return headPoints
    }

    /// Get best focus point
    /// Priority: midpoint between two eyes → single eye → body center
    private func getBestFocusPoint(
        eyes: [EyeDetection],
        boundingBox: CGRect
    ) -> CGPoint {
        // 1. Priority: midpoint between two eyes (most accurate)
        if eyes.count >= 2 {
            let leftEye = eyes[0].position
            let rightEye = eyes[1].position
            return CGPoint(
                x: (leftEye.x + rightEye.x) / 2.0,
                y: (leftEye.y + rightEye.y) / 2.0
            )
        }

        // 2. Secondary: single eye position
        if let singleEye = eyes.first {
            return singleEye.position
        }

        // 3. Fallback: body center (bounding box center)
        return CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }

    /// Select best subject for focus from multiple subjects
    /// Priority: center region > confidence > size
    private func selectBestSubjectForFocus(from subjects: [SubjectDetectionResult]) -> SubjectDetectionResult? {
        guard !subjects.isEmpty else { return nil }

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
}

@MainActor
class SubjectDetector: NSObject {

    // Auto-focus callback (triggered when new subject is detected)
    var onAutoFocus: ((CGPoint) -> Void)?

    // Subject detection callback (for displaying subject bounding boxes and angle guidance)
    // Parameters: (all subjects, primary subject ID) - nil means no subjects detected
    var onSubjectsDetected: (([SubjectDetectionResult], UUID?) -> Void)?

    // Portrait condition update callback (passes all detected subjects + salient objects)
    var onPortraitConditionsUpdate: (([SubjectDetectionResult], CGRect?) -> Void)?

    private let logger = Logger(subsystem: Log.subsystem, category: "SubjectDetector")

    // Subject detection stability control (iPhone style)
    @MainActor private var lastAllSubjectDetections: [SubjectDetectionResult] = []  // All detected subjects (for UI)
    @MainActor private var lastSubjectsForPortrait: [SubjectDetectionResult] = []  // Portrait-specific cache (independent longer grace period)
    @MainActor private var primarySubjectID: UUID? = nil  // Primary subject ID (for UI identification)
    @MainActor private var subjectDetectionStableCount: Int = 0  // Number of consecutive subject detections
    private let stableThreshold: Int = 2  // Need 2 consecutive detections to show (~100ms, faster response)
    private let subjectMatchThreshold: CGFloat = 0.15  // Subject position matching threshold (15% screen distance)

    // Subject disappearance grace period (prevent bounding box flicker from detection fluctuations)
    @MainActor private var subjectDisappearanceCount: Int = 0  // Number of consecutive non-detections
    private let disappearanceGracePeriod: Int = 3  // Grace period: 3 consecutive misses (~600ms at 5fps) before hiding bounding box

    // Portrait-specific disappearance timer (uses time instead of frame count, more stable)
    @MainActor private var portraitSubjectLastSeenTime: Date = .distantPast
    private let portraitGraceDuration: TimeInterval = 3.0  // Portrait grace period: 3 seconds (Vision detection sometimes misses multiple frames)

    // Head box stability control (prevent frequent switching between head and body boxes)
    @MainActor private var lastValidHeadBox: CGRect? = nil  // Last valid head box
    @MainActor private var headBoxDisappearCount: Int = 0  // Frames since head box disappeared
    private let headBoxGracePeriod: Int = 8  // Head box grace period: 8 consecutive frames (~400ms) without head box before switching to body box

    // Used to detect subject position changes and trigger bounding box re-display
    @MainActor private var lastDisplayedBoundingBox: CGRect? = nil

    // Last detected subject position (to determine if refocus is needed)
    @MainActor private var lastSubjectCenter: CGPoint?
    @MainActor private var lastFocusPoint: CGPoint?  // Last actual focus trigger point
    private let refocusThreshold: CGFloat = 0.08  // Subject movement > 8% triggers refocus (faster response)


    // Detection interval configuration - same for all modes
    // With detect-then-track, tracking frames are ~12ms, detection ~30-35ms
    private let fastInterval: TimeInterval = 0.1      // 100ms (~10fps) - when subject detected (tracking frames ~15ms each)
    private let normalInterval: TimeInterval = 0.5    // 500ms (~2fps) - when no subject detected (all detection frames)
    private let slowInterval: TimeInterval = 1.0      // 1s (~1fps) - when no subject for long time

    /// Whether Shot Guide needs pose detection (eyes/head tracking)
    /// When false, skips pose detection during re-detection frames
    var needsHighFrequencyDetection: Bool = false

    /// Lightweight main-thread throttle to avoid spawning Tasks that the actor throttler would reject
    private var lastDetectionDispatchTime: CFAbsoluteTime = 0
    /// Minimum interval between Task dispatches (slightly less than fastest detection interval)
    private let minDispatchInterval: TimeInterval = 0.06  // 60ms — allows ~16 Task dispatches/sec for 10fps tracking

    // Minimum confidence thresholds
    private let minConfidenceThreshold: Float = 0.45  // Saliency detection confidence threshold (balance iPhone behavior)
    private let minSubjectConfidenceThreshold: Float = 0.45  // Subject detection confidence threshold (aligned with iOS native behavior)

    // Vision pipeline (isolates requests and throttling)
    private let visionPipeline: VisionPipeline

    // Initializer - preload Vision models
    override init() {
        self.visionPipeline = VisionPipeline(
            minConfidenceThreshold: minConfidenceThreshold,
            minSubjectConfidenceThreshold: minSubjectConfidenceThreshold
        )
        super.init()

        // Preload Vision models to reduce first detection delay
        Task {
            await visionPipeline.preloadModels()
        }
    }

    /// Reset tracking state (call on camera switch, stop, etc.)
    func resetTracking() {
        Task {
            await visionPipeline.resetTracking()
        }
    }

    /// Detect subjects in sample buffer
    /// - Parameters:
    ///   - sampleBuffer: The video frame to process
    ///   - isFrontCamera: Whether the front camera is active (affects Vision orientation)
    func detectSubjects(in sampleBuffer: CMSampleBuffer, isFrontCamera: Bool = false) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        detectSubjects(in: pixelBuffer, isFrontCamera: isFrontCamera)
    }

    /// Detect subjects in pixel buffer
    /// - Parameters:
    ///   - pixelBuffer: The pixel buffer to process
    ///   - isFrontCamera: Whether the front camera is active (affects Vision orientation)
    func detectSubjects(in pixelBuffer: CVPixelBuffer, isFrontCamera: Bool = false) {
        // Lightweight main-thread throttle: skip Task creation if called too frequently
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDetectionDispatchTime >= minDispatchInterval else { return }
        lastDetectionDispatchTime = now

        // Hand Vision processing to independent actor, avoiding actor isolation bypass
        let fast = fastInterval
        let normal = normalInterval
        let slow = slowInterval
        let skipPose = !needsHighFrequencyDetection  // Only need pose detection for Shot Guide eye tracking
        let pipeline = visionPipeline
        let pixelBufferBox = PixelBufferBox(buffer: pixelBuffer)

        Task.detached(priority: .userInitiated) { [weak self, pixelBufferBox, pipeline, fast, normal, slow, skipPose, isFrontCamera] in
            let detectionResult = await pipeline.processFrame(
                pixelBufferBox: pixelBufferBox,
                isFrontCamera: isFrontCamera,
                fastInterval: fast,
                normalInterval: normal,
                slowInterval: slow,
                skipPoseDetection: skipPose
            )

            guard let detectionResult = detectionResult else { return }

            await MainActor.run {
                self?.handleDetectionResult(detectionResult, pixelBuffer: pixelBufferBox.buffer)
            }
        }
    }

    // MARK: - Result Processing (Main Thread)

    @MainActor
    private func handleDetectionResult(_ detectionResult: VisionDetectionOutput, pixelBuffer: CVPixelBuffer? = nil) {
        // First update stable subject detection (will update lastAllSubjectDetections for UI)
        updateStableSubjectDetection(allSubjects: detectionResult.subjectDetections, primarySubject: detectionResult.bestSubject, isTrackingFrame: detectionResult.isTrackingFrame)

        // Portrait uses independent cache and longer grace period
        // 🔑 Key: Portrait has its own fault tolerance mechanism, independent from UI bounding boxes
        updatePortraitSubjectCache(currentSubjects: detectionResult.subjectDetections)
        onPortraitConditionsUpdate?(lastSubjectsForPortrait, detectionResult.salientObjectBoundingBox)

        if let currentCenter = detectionResult.focusCandidate {
            var shouldFocus = false
            if let lastFocus = lastFocusPoint {
                let deltaX = abs(currentCenter.x - lastFocus.x)
                let deltaY = abs(currentCenter.y - lastFocus.y)
                if deltaX > refocusThreshold || deltaY > refocusThreshold {
                    shouldFocus = true
                }
            } else {
                shouldFocus = true
            }
            lastSubjectCenter = currentCenter
            if shouldFocus {
                lastFocusPoint = currentCenter
                onAutoFocus?(currentCenter)
            }
        } else {
            lastSubjectCenter = nil
            lastFocusPoint = nil
        }
    }

    // MARK: - Subject Detection Optimization (Multi-subject Support)

    /// Subject detection logic (iPhone native camera style, multi-subject support)
    /// - Subjects detected → show bounding boxes for all subjects
    /// - Primary subject (focus target) shows eye indicator
    /// - Subjects disappear → hide bounding boxes
    @MainActor
    private func updateStableSubjectDetection(allSubjects: [SubjectDetectionResult], primarySubject: SubjectDetectionResult?, isTrackingFrame: Bool = false) {
        if !allSubjects.isEmpty, let newSubject = primarySubject {
            // Subjects detected → reset disappearance counter
            subjectDisappearanceCount = 0

            // 🎯 Handle head box stability for primary subject
            var stableHeadBox: CGRect? = nil

            if let currentHeadBox = newSubject.headBoundingBox {
                let isHeadBoxValid = isHeadBoxWithinBody(headBox: currentHeadBox, bodyBox: newSubject.boundingBox)
                if isHeadBoxValid {
                    lastValidHeadBox = currentHeadBox
                    headBoxDisappearCount = 0
                    stableHeadBox = currentHeadBox
                }
            } else if isTrackingFrame {
                // During tracking frames, nil head/eyes is expected (pose not run)
                // Preserve last known head box without incrementing disappear count
                stableHeadBox = lastValidHeadBox
            } else {
                headBoxDisappearCount += 1
                if headBoxDisappearCount < headBoxGracePeriod, let lastHead = lastValidHeadBox {
                    stableHeadBox = lastHead
                } else {
                    lastValidHeadBox = nil
                }
            }

            // Create stable primary subject detection result (with head box and eyes)
            let stablePrimarySubject = SubjectDetectionResult(
                boundingBox: newSubject.boundingBox,
                headBoundingBox: stableHeadBox,
                confidence: newSubject.confidence,
                animalType: newSubject.animalType,
                eyes: newSubject.eyes
            )

            // Process all subjects (non-primary subjects don't show eyes)
            // Use nearest distance matching algorithm to keep ID stable, prevent UI jumping
            let matchedIDs = matchSubjectsWithIDs(newSubjects: allSubjects)
            var stableAllSubjects: [SubjectDetectionResult] = []
            var currentPrimaryID: UUID? = nil

            for (index, subject) in allSubjects.enumerated() {
                let isPrimary = subject.boundingBox == newSubject.boundingBox
                let subjectID = matchedIDs[index]

                if isPrimary {
                    // Primary subject - use stable version with head box and eyes
                    let stableSubject = SubjectDetectionResult(
                        boundingBox: stablePrimarySubject.boundingBox,
                        headBoundingBox: stablePrimarySubject.headBoundingBox,
                        confidence: stablePrimarySubject.confidence,
                        animalType: stablePrimarySubject.animalType,
                        eyes: stablePrimarySubject.eyes,
                        id: subjectID
                    )
                    stableAllSubjects.append(stableSubject)
                    currentPrimaryID = subjectID
                } else {
                    // Other subjects - only show bounding box, no eyes
                    let otherSubject = SubjectDetectionResult(
                        boundingBox: subject.boundingBox,
                        headBoundingBox: nil,
                        confidence: subject.confidence,
                        animalType: subject.animalType,
                        eyes: [],
                        id: subjectID
                    )
                    stableAllSubjects.append(otherSubject)
                }
            }

            // Update primary subject ID
            primarySubjectID = currentPrimaryID

            let currentBox = stablePrimarySubject.displayBoundingBox

            // Accumulate stability counter (for initial detection only)
            if subjectDetectionStableCount < stableThreshold {
                subjectDetectionStableCount += 1
            }

            // Need consecutive detections to confirm initial bounding box display
            if subjectDetectionStableCount == stableThreshold {
                lastDisplayedBoundingBox = currentBox
                lastAllSubjectDetections = stableAllSubjects
                onSubjectsDetected?(stableAllSubjects, currentPrimaryID)
            }
            // Once stable, always update bounding box position (continuous tracking)
            else if subjectDetectionStableCount > stableThreshold {
                lastDisplayedBoundingBox = currentBox
                lastAllSubjectDetections = stableAllSubjects
                onSubjectsDetected?(stableAllSubjects, currentPrimaryID)
            }
        } else {
            // No subjects detected → increment disappearance counter
            subjectDisappearanceCount += 1

            // Grace period: only hide bounding box after multiple consecutive non-detections
            if subjectDisappearanceCount >= disappearanceGracePeriod {
                if subjectDetectionStableCount > 0 {
                    onSubjectsDetected?([], nil)  // Hide all bounding boxes
                }

                // Reset state
                subjectDetectionStableCount = 0
                lastDisplayedBoundingBox = nil
                lastValidHeadBox = nil
                headBoxDisappearCount = 0
                lastAllSubjectDetections = []
                primarySubjectID = nil
            }
        }
    }

    // MARK: - Portrait-specific Cache Management

    /// Update Portrait-specific subject cache (independent from UI, uses time calculation for more stability)
    @MainActor
    private func updatePortraitSubjectCache(currentSubjects: [SubjectDetectionResult]) {
        let now = Date()

        if !currentSubjects.isEmpty {
            // Subjects detected → update cache and timestamp
            lastSubjectsForPortrait = currentSubjects
            portraitSubjectLastSeenTime = now
        } else {
            // No subjects detected → check if grace duration exceeded
            let timeSinceLastSeen = now.timeIntervalSince(portraitSubjectLastSeenTime)

            if timeSinceLastSeen >= portraitGraceDuration {
                // Exceeded grace time, clear cache
                lastSubjectsForPortrait = []
            }
            // Otherwise keep lastSubjectsForPortrait unchanged, let Portrait continue using cached data
        }
    }

    /// Use nearest distance priority matching algorithm to assign stable IDs to newly detected subjects
    /// Avoid incorrect ID assignment when multiple subjects are close together
    ///
    /// PERFORMANCE: Optimized with early exits and pre-computed centers
    /// - O(n*m) where n = new subjects, m = old subjects (typically 1-4 each)
    /// - Early exit when all subjects are matched
    /// - Pre-compute centers to avoid repeated midX/midY calculations
    @MainActor
    private func matchSubjectsWithIDs(newSubjects: [SubjectDetectionResult]) -> [UUID] {
        // Early exit: no previous detections to match against
        guard !lastAllSubjectDetections.isEmpty else {
            return newSubjects.map { _ in UUID() }
        }

        // Early exit: no new subjects to match
        guard !newSubjects.isEmpty else {
            return []
        }

        // Initialize independent new UUID for each new subject (used when unmatched)
        var result: [UUID] = newSubjects.map { _ in UUID() }
        var usedOldIndices: Set<Int> = []

        // Pre-compute centers for all old subjects (avoid repeated calculations)
        let oldCenters = lastAllSubjectDetections.map { subject in
            CGPoint(x: subject.boundingBox.midX, y: subject.boundingBox.midY)
        }

        // Calculate distances between all new and old subjects
        // Pre-allocate capacity to avoid repeated array reallocations
        var distances: [(newIndex: Int, oldIndex: Int, distance: CGFloat)] = []
        distances.reserveCapacity(newSubjects.count * lastAllSubjectDetections.count)

        for (newIndex, newSubject) in newSubjects.enumerated() {
            let newCenter = CGPoint(x: newSubject.boundingBox.midX, y: newSubject.boundingBox.midY)

            for (oldIndex, oldCenter) in oldCenters.enumerated() {
                let distance = hypot(newCenter.x - oldCenter.x, newCenter.y - oldCenter.y)

                if distance < subjectMatchThreshold {
                    distances.append((newIndex, oldIndex, distance))
                }
            }
        }

        // Sort by distance (nearest match first)
        distances.sort { $0.distance < $1.distance }

        // Greedy matching: each new subject can only match one old subject, each old subject can only be matched once
        var matchedNewIndices: Set<Int> = []
        let maxMatches = min(newSubjects.count, lastAllSubjectDetections.count)

        for match in distances {
            // Early exit: all possible matches done
            if matchedNewIndices.count >= maxMatches { break }

            if !matchedNewIndices.contains(match.newIndex) && !usedOldIndices.contains(match.oldIndex) {
                result[match.newIndex] = lastAllSubjectDetections[match.oldIndex].id
                matchedNewIndices.insert(match.newIndex)
                usedOldIndices.insert(match.oldIndex)
            }
        }

        return result
    }

    /// Check if head box is reasonably located within body box
private func isHeadBoxWithinBody(headBox: CGRect, bodyBox: CGRect) -> Bool {
    // Head box should have significant overlap with body box
    let intersection = headBox.intersection(bodyBox)
    if intersection.isNull { return false }

    let headArea = headBox.width * headBox.height
    let intersectionArea = intersection.width * intersection.height

    // Head box should have at least 50% overlap with body box
    return intersectionArea / headArea >= 0.5
}
}

// Main thread isolated class, needs Sendable declaration when used for weak reference capture
extension SubjectDetector: @unchecked Sendable {}

