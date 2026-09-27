//
//  LivePhotoManager.swift
//  CameraStarter
//
//  Live Photo capture manager
//  Uses actor for thread safety and timeout cleanup
//

import AVFoundation
import Foundation
import os.log

/// Live Photo capture state
private struct LivePhotoCapture: Sendable {
    var photoData: Data?
    var movieURL: URL?
    var isMovieProcessed: Bool
    var startTime: Date

    init(photoData: Data? = nil, movieURL: URL? = nil, isMovieProcessed: Bool = false) {
        self.photoData = photoData
        self.movieURL = movieURL
        self.isMovieProcessed = isMovieProcessed
        self.startTime = Date()
    }
}

/// Live Photo capture manager
/// Uses actor for thread safety, auto-cleans timed out and failed captures
actor LivePhotoManager {
    private let logger = Logger(subsystem: Log.subsystem, category: "LivePhotoManager")

    // Capture state dictionary
    private var captures: [Int64: LivePhotoCapture] = [:]

    // Pending continuations for async waiting
    private var pendingContinuations: [Int64: CheckedContinuation<(photoData: Data, movieURL: URL)?, Never>] = [:]

    // Configuration
    private let maxConcurrent = 3
    private let timeout: TimeInterval = 10.0  // 10 second timeout

    /// Start Live Photo capture
    /// - Parameters:
    ///   - id: Photo unique ID
    ///   - movieURL: Video file URL
    /// - Returns: Whether successfully started (false if concurrent limit reached)
    func startCapture(id: Int64, movieURL: URL) async -> Bool {
        // Clean up timed out captures
        await cleanupTimedOutCaptures()

        // Check concurrent limit
        guard captures.count < maxConcurrent else {
            logger.warning("Live Photo capture limit reached (\(self.maxConcurrent))")
            return false
        }

        captures[id] = await LivePhotoCapture(movieURL: movieURL)
        return true
    }

    /// Complete photo capture
    /// - Parameters:
    ///   - id: Photo unique ID
    ///   - photo: Captured photo
    func completePhotoCapture(id: Int64, photo: AVCapturePhoto) {
        guard let capture = captures[id] else {
            logger.warning("Photo capture completed but no matching Live Photo record: \(id)")
            return
        }

        var updated = capture

        // Convert AVCapturePhoto to Data on the main actor (AVCapturePhoto is main-actor isolated)
        updated.photoData = photo.fileDataRepresentation()

        captures[id] = updated

        // Check if we have a waiting continuation and the capture is now complete
        tryResumeWaitingContinuation(id: id)
    }

    /// Complete movie processing
    /// - Parameter id: Photo unique ID
    func completeMovieProcessing(id: Int64) {
        guard let capture = captures[id] else {
            logger.warning("Movie processing completed but no matching Live Photo record: \(id)")
            return
        }

        var updated = capture
        updated.isMovieProcessed = true
        captures[id] = updated

        // Check if we have a waiting continuation and the capture is now complete
        tryResumeWaitingContinuation(id: id)
    }

    /// Try to resume a waiting continuation if capture is complete
    private func tryResumeWaitingContinuation(id: Int64) {
        guard let continuation = pendingContinuations[id],
              let capture = captures[id],
              capture.isMovieProcessed,
              let photoData = capture.photoData,
              let movieURL = capture.movieURL else {
            return
        }

        // Remove continuation and capture
        pendingContinuations.removeValue(forKey: id)
        captures.removeValue(forKey: id)

        // Resume with completed capture
        continuation.resume(returning: (photoData, movieURL))
    }

    /// Get completed Live Photo (both photo and video done)
    /// - Parameter id: Photo unique ID
    /// - Returns: Completed photo data and video URL, nil if not complete
    func getCompletedCapture(id: Int64) -> (photoData: Data, movieURL: URL)? {
        guard let capture = captures[id],
              capture.isMovieProcessed,
              let photoData = capture.photoData,
              let movieURL = capture.movieURL else {
            return nil
        }

        // Clean up after returning
        captures.removeValue(forKey: id)
        return (photoData, movieURL)
    }

    /// Wait for Live Photo capture to complete (async version - no polling)
    /// Uses continuation-based async/await instead of polling with Task.sleep
    /// - Parameters:
    ///   - id: Photo unique ID
    ///   - timeout: Maximum time to wait in seconds
    /// - Returns: Completed photo data and video URL, nil if timeout or not started
    func waitForCompletedCapture(id: Int64, timeout: TimeInterval = 8.0) async -> (photoData: Data, movieURL: URL)? {
        // Check if already complete
        if let completed = getCompletedCapture(id: id) {
            return completed
        }

        // Check if capture exists
        guard captures[id] != nil else {
            return nil
        }

        // Wait using continuation with timeout
        // Store continuation in actor context, then wait in a race
        return await withCheckedContinuation { continuation in
            // Store continuation to be resumed when complete
            self.pendingContinuations[id] = continuation

            // Start timeout task
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If continuation still pending, resume with nil (timeout)
                self.handleTimeout(id: id)
            }
        }
    }

    /// Handle timeout for waiting capture
    private func handleTimeout(id: Int64) {
        // Only resume if continuation is still pending (not already resumed by completion)
        if let continuation = pendingContinuations.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        }
    }

    /// Cancel capture and cleanup resources
    /// - Parameter id: Photo unique ID
    func cancelCapture(id: Int64) {
        guard let capture = captures[id] else { return }

        // Clean up temp video file
        if let movieURL = capture.movieURL {
            try? FileManager.default.removeItem(at: movieURL)
        }

        // Resume any pending continuation with nil
        if let continuation = pendingContinuations.removeValue(forKey: id) {
            continuation.resume(returning: nil)
        }

        captures.removeValue(forKey: id)
    }

    /// Clean up all timed out captures
    private func cleanupTimedOutCaptures() async {
        let now = Date()
        let timedOut = captures.filter {
            now.timeIntervalSince($0.value.startTime) > timeout
        }

        for (id, capture) in timedOut {
            // Clean up temp video file
            if let movieURL = capture.movieURL {
                try? FileManager.default.removeItem(at: movieURL)
            }

            captures.removeValue(forKey: id)
        }
    }

    /// Clean up all captures (when camera stops)
    func cleanup() async {
        for (_, capture) in captures {
            if let movieURL = capture.movieURL {
                try? FileManager.default.removeItem(at: movieURL)
            }
        }

        // Resume all pending continuations with nil
        for (_, continuation) in pendingContinuations {
            continuation.resume(returning: nil)
        }

        captures.removeAll()
        pendingContinuations.removeAll()
    }
}


