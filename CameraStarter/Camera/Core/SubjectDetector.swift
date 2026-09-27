//
//  SubjectDetector.swift
//  CameraStarter
//
//  Finds what the camera should focus on. Each full pass looks for faces,
//  people and animals with Vision, and falls back to the most salient region
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

/// What a detected subject is.
nonisolated enum SubjectKind: Equatable, Sendable, CustomStringConvertible {
    case face
    /// A person whose face wasn't found: turned away, or too far off.
    case person
    /// An animal, with Vision's label for it ("Cat" or "Dog").
    case animal(String)

    var description: String {
        switch self {
        case .face: "face"
        case .person: "person"
        case .animal(let label): label.lowercased()
        }
    }
}

/// Subject detection result
nonisolated struct SubjectDetectionResult: Equatable, Sendable, Identifiable {
    let id: UUID  // Stable unique identifier (for UI tracking)
    let boundingBox: CGRect  // Subject bounding box (normalized coordinates 0-1)
    let confidence: Float    // Confidence score
    let kind: SubjectKind

    /// Convenience initializer (auto-generates ID)
    init(boundingBox: CGRect, confidence: Float, kind: SubjectKind, id: UUID = UUID()) {
        self.id = id
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.kind = kind
    }

}

/// Vision detection output (for main thread use)
private struct VisionDetectionOutput: Sendable {
    let subjectDetections: [SubjectDetectionResult]
    let bestSubject: SubjectDetectionResult?
    let focusCandidate: CGPoint?
    let salientObjectBoundingBox: CGRect?
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
    var cachedKind: SubjectKind
    var cachedConfidence: Float
}

/// A subject from a full detection pass, with the observation to start its
/// tracker from.
nonisolated private struct DetectedSubject {
    let observation: VNDetectedObjectObservation
    let result: SubjectDetectionResult

    init(_ observation: VNDetectedObjectObservation, kind: SubjectKind) {
        self.observation = observation
        self.result = SubjectDetectionResult(
            boundingBox: observation.boundingBox,
            confidence: observation.confidence,
            kind: kind
        )
    }
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

    private let faceRequest = VNDetectFaceRectanglesRequest()

    private let humanRequest: VNDetectHumanRectanglesRequest = {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false  // Whole people, including ones seen from a distance
        return request
    }()

    private let animalRequest: VNRecognizeAnimalsRequest = {
        let request = VNRecognizeAnimalsRequest()
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
            try handler.perform([saliencyRequest, faceRequest, humanRequest, animalRequest])
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
        slowInterval: TimeInterval
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
                slowInterval: slowInterval
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

    /// Full ML detection (expensive: faces, people and animals, then saliency when none)
    private func runFullDetection(
        pixelBufferBox: PixelBufferBox,
        orientation: CGImagePropertyOrientation,
        fastInterval: TimeInterval,
        normalInterval: TimeInterval,
        slowInterval: TimeInterval
    ) async -> VisionDetectionOutput? {
        let imageRequestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBufferBox.buffer,
            orientation: orientation,
            options: [:]
        )

        do {
            // 1) Run subject recognition, all kinds in one pass over the frame
            try imageRequestHandler.perform([faceRequest, humanRequest, animalRequest])
            let detectedSubjects = collectDetectedSubjects()

            // 2) Only run saliency when no subjects detected, as focus fallback
            var salientObjects: [VNDetectedObjectObservation] = []
            if detectedSubjects.isEmpty {
                try imageRequestHandler.perform([saliencyRequest])
                if let saliencyResult = saliencyRequest.results?.first,
                   let objects = saliencyResult.salientObjects {
                    salientObjects = objects
                }
            }

            let allSubjectDetections = detectedSubjects.map(\.result)

            // Initialize trackers from fresh detection results
            await initializeTrackers(from: detectedSubjects)

            // Select best subject for focus
            let subjectDetectionResult = selectBestSubjectForFocus(from: allSubjectDetections)

            // Determine focus point
            var focusCenter: CGPoint? = nil
            if let subjectResult = subjectDetectionResult {
                focusCenter = CGPoint(x: subjectResult.boundingBox.midX, y: subjectResult.boundingBox.midY)
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
                salientObjectBoundingBox: salientObjectBox
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

                allSubjectDetections.append(SubjectDetectionResult(
                    boundingBox: updatedObservation.boundingBox,
                    confidence: blendedConfidence,
                    kind: subject.cachedKind,
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

        // Focus uses the bounding box center during tracking
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
            salientObjectBoundingBox: nil  // No saliency during tracking
        )
    }

    /// The subjects in the frame the requests just ran on, above the
    /// confidence threshold.
    private func collectDetectedSubjects() -> [DetectedSubject] {
        let isConfident = { (observation: VNDetectedObjectObservation) in
            observation.confidence > self.minSubjectConfidenceThreshold
        }

        let faces = (faceRequest.results ?? []).filter(isConfident)

        // A person whose face was found is already covered by that face,
        // which is the better thing to focus on.
        let people = (humanRequest.results ?? []).filter(isConfident).filter { person in
            !faces.contains { face in
                person.boundingBox.contains(CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY))
            }
        }

        let animals = (animalRequest.results ?? []).filter(isConfident)

        return faces.map { DetectedSubject($0, kind: .face) }
            + people.map { DetectedSubject($0, kind: .person) }
            + animals.map { DetectedSubject($0, kind: .animal($0.labels.first?.identifier ?? "Animal")) }
    }

    /// Initialize trackers from fresh detection results
    private func initializeTrackers(from detectedSubjects: [DetectedSubject]) async {
        // Reset tracking state
        trackedSubjects = []
        framesSinceLastDetection = 0
        // Recreate sequence handler to prevent unbounded memory growth
        sequenceHandler = VNSequenceRequestHandler()

        for subject in detectedSubjects {
            let observation = subject.observation

            // Create initial track request on MainActor (Vision request types are MainActor-isolated)
            let trackRequest: VNTrackObjectRequest = await MainActor.run {
                let req = VNTrackObjectRequest(detectedObjectObservation: observation)
                req.trackingLevel = .fast
                return req
            }

            trackedSubjects.append(TrackedSubjectState(
                id: subject.result.id,
                trackRequest: trackRequest,
                lastTrackingConfidence: observation.confidence,
                cachedKind: subject.result.kind,
                cachedConfidence: observation.confidence
            ))
        }
    }

    /// Reset all tracking state (called on camera switch, stop, etc.)
    func resetTracking() {
        trackedSubjects = []
        framesSinceLastDetection = 0
        sequenceHandler = VNSequenceRequestHandler()
    }

    // MARK: - Focus Selection

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

    // Subject detection callback (for the tracking boxes)
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
        let pipeline = visionPipeline
        let pixelBufferBox = PixelBufferBox(buffer: pixelBuffer)

        Task.detached(priority: .userInitiated) { [weak self, pixelBufferBox, pipeline, fast, normal, slow, isFrontCamera] in
            let detectionResult = await pipeline.processFrame(
                pixelBufferBox: pixelBufferBox,
                isFrontCamera: isFrontCamera,
                fastInterval: fast,
                normalInterval: normal,
                slowInterval: slow
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
        updateStableSubjectDetection(allSubjects: detectionResult.subjectDetections, primarySubject: detectionResult.bestSubject)

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
    /// - Subjects disappear → hide bounding boxes
    @MainActor
    private func updateStableSubjectDetection(allSubjects: [SubjectDetectionResult], primarySubject: SubjectDetectionResult?) {
        if !allSubjects.isEmpty, let newSubject = primarySubject {
            // Subjects detected → reset disappearance counter
            subjectDisappearanceCount = 0

            // Process all subjects
            // Use nearest distance matching algorithm to keep ID stable, prevent UI jumping
            let matchedIDs = matchSubjectsWithIDs(newSubjects: allSubjects)
            var stableAllSubjects: [SubjectDetectionResult] = []
            var currentPrimaryID: UUID? = nil

            for (index, subject) in allSubjects.enumerated() {
                let isPrimary = subject.boundingBox == newSubject.boundingBox
                let subjectID = matchedIDs[index]

                if isPrimary {
                    let stableSubject = SubjectDetectionResult(
                        boundingBox: newSubject.boundingBox,
                        confidence: newSubject.confidence,
                        kind: newSubject.kind,
                        id: subjectID
                    )
                    stableAllSubjects.append(stableSubject)
                    currentPrimaryID = subjectID
                } else {
                    let otherSubject = SubjectDetectionResult(
                        boundingBox: subject.boundingBox,
                        confidence: subject.confidence,
                        kind: subject.kind,
                        id: subjectID
                    )
                    stableAllSubjects.append(otherSubject)
                }
            }

            // Update primary subject ID
            primarySubjectID = currentPrimaryID

            let currentBox = newSubject.boundingBox

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

}

// Main thread isolated class, needs Sendable declaration when used for weak reference capture
extension SubjectDetector: @unchecked Sendable {}

