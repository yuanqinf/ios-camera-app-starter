//
//  DataModel.swift
//  CameraStarter
//
//  Created by Yuanqin Fan on 11/10/25.
//

import AVFoundation
import SwiftUI
import os.log
import Photos
import CoreLocation
import UIKit
import UniformTypeIdentifiers
import ImageIO

@Observable
final class DataModel {
    let camera = CameraManager()
    let photoCollection = AlbumManager.shared
    let thumbnailCache = ThumbnailCache()
    let timer = CameraTimerManager()
    // Portrait mode: depth data embedded in photo, user can adjust blur in iOS Photos app

    var thumbnailImage: Image?

    /// Current thumbnail asset ID (to avoid unnecessary updates)
    private var currentThumbnailAssetID: String?

    var isPhotosLoaded = false

    /// Whether a photo is currently being saved
    var isSavingPhoto = false

    /// Callback when a photo is saved, provides the asset ID for auto-import to gallery
    var onPhotoSaved: ((String) -> Void)?

    /// Callback when a video is saved, provides the asset ID for auto-import to gallery
    var onVideoSaved: ((String) -> Void)?

    /// Callback when any photo is saved (for thumbnail feedback animation - green border)
    var onPhotoThumbnailUpdated: (() -> Void)?

    /// Background tasks for stream processing (stored for cancellation)
    private var streamTasks: [Task<Void, Never>] = []

    /// Last captured full-resolution image (for instant MediaViewer display)
    /// This is cleared when the user navigates away from camera or views the photo
    var lastCapturedImage: Image?

    /// Clear the cached captured image (call when user has viewed the photo or navigated away)
    func clearLastCapturedImage() {
        lastCapturedImage = nil
    }

    /// Update the current thumbnail asset ID (call after photo is added to gallery)
    func updateThumbnailAssetID(_ assetID: String) {
        currentThumbnailAssetID = assetID
    }

    init() {
        // Load cached thumbnail immediately (synchronous, no waiting)
        thumbnailImage = thumbnailCache.loadCachedThumbnail()
        // Also restore the cached asset ID to prevent unnecessary reloads
        currentThumbnailAssetID = thumbnailCache.getCachedAssetIdentifier()

        // Store task references for potential cancellation
        streamTasks.append(Task {
            await handleCameraPhotos()
        })

        streamTasks.append(Task {
            await handleDeferredPhotos()
        })

        streamTasks.append(Task {
            await handleVideoRecordings()
        })
    }

    deinit {
        // Cancel all background tasks
        for task in streamTasks {
            task.cancel()
        }
    }

    /// Handle video recording stream
    /// Save each finished recording to the app's album
    func handleVideoRecordings() async {
        for await (url, location) in camera.videoStream {
            await saveVideo(url: url, location: location)
        }
    }

    func handleCameraPhotos() async {
        // Process photo stream directly without compactMap (avoid blocking)
        for await (photo, location) in camera.photoStream {
            // Extract image orientation info
            let metadataOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32
            let cgImageOrientation = metadataOrientation.flatMap { CGImagePropertyOrientation(rawValue: $0) }

            let cgImage = photo.cgImageRepresentation()

            // Use orientation from metadata, fallback to .up if not available
            let imageOrientation: Image.Orientation = cgImageOrientation.map { Image.Orientation($0) } ?? .up

            // ⚡ Step 2: Update thumbnail (prefer preview, fallback to full resolution)
            let thumbnailCGImage = photo.previewCGImageRepresentation() ?? cgImage
            if let thumbnailCGImage {
                let thumbnailImage = Image(decorative: thumbnailCGImage, scale: 1, orientation: imageOrientation)

                // 🚀 Immediately synchronous update + trigger green feedback
                await MainActor.run {
                    self.thumbnailImage = thumbnailImage
                    self.isSavingPhoto = true
                    self.onPhotoThumbnailUpdated?()
                }
            }

            // ⚡ Step 3: Extract full resolution image for instant preview
            if let cgImage {
                let fullImage = Image(decorative: cgImage, scale: 1, orientation: imageOrientation)

                await MainActor.run {
                    self.lastCapturedImage = fullImage
                }
            }

            // Check if Live Photo is enabled (system Live Photo has valid movie dimensions)
            let isLivePhoto = photo.resolvedSettings.livePhotoMovieDimensions.width > 0

            // Step 3: Async process full photo and save (doesn't block thumbnail update)
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let strongSelf = self else { return }
                if let photoData = await strongSelf.unpackPhoto(photo, location: location, isLivePhoto: isLivePhoto) {
                    if isLivePhoto {
                        await strongSelf.saveLivePhoto(photoData: photoData, photo: photo)
                    } else {
                        await MainActor.run { [strongSelf] in
                            strongSelf.savePhoto(photoData: photoData)
                        }
                    }
                }
            }
        }
    }

    /// Handle deferred photo stream (Deferred Photo Processing)
    /// System completes Deep Fusion / Photonic Engine computational photography in background
    func handleDeferredPhotos() async {
        for await (proxy, location) in camera.deferredPhotoStream {
            // Extract orientation from metadata (fallback to .up if not available)
            let metadataOrientation = proxy.metadata[String(kCGImagePropertyOrientation)] as? UInt32
            let cgImageOrientation = metadataOrientation.flatMap { CGImagePropertyOrientation(rawValue: $0) }
            let imageOrientation: Image.Orientation = cgImageOrientation.map { Image.Orientation($0) } ?? .up

            // Get image for thumbnail - prefer preview, fallback to full resolution
            let thumbnailCGImage = proxy.previewCGImageRepresentation() ?? proxy.cgImageRepresentation()
            let fullCGImage = proxy.cgImageRepresentation()

            // Update thumbnail immediately
            if let thumbnailCGImage {
                let thumbnailImage = Image(decorative: thumbnailCGImage, scale: 1, orientation: imageOrientation)

                await MainActor.run {
                    self.thumbnailImage = thumbnailImage
                    self.isSavingPhoto = true
                    self.onPhotoThumbnailUpdated?()
                }
            }

            // Extract full resolution image for instant preview
            if let fullCGImage {
                let fullImage = Image(decorative: fullCGImage, scale: 1, orientation: imageOrientation)

                await MainActor.run {
                    self.lastCapturedImage = fullImage
                }
            }

            // Save deferred photo proxy
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let strongSelf = self else { return }
                await strongSelf.saveDeferredPhoto(proxy: proxy, location: location)
            }
        }
    }

    @MainActor
    private func saveDeferredPhoto(proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?) async {
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SaveDeferredPhoto") {
            // Expiration handler - task is ending, clean up
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        // Use defer to guarantee cleanup even if exceptions occur
        defer {
            self.isSavingPhoto = false
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        let collection = self.photoCollection
        let onSaved = self.onPhotoSaved

        do {
            let assetID = try await collection.addDeferredPhoto(proxy, location: location)

            // Schedule GPS restoration after deferred processing completes
            // System replaces the photo file during processing, losing GPS EXIF
            // DeferredPhotoGPSRestorer waits for processing and re-writes GPS
            if let assetID = assetID, let location = location {
                DeferredPhotoGPSRestorer.shared.scheduleRestoration(for: assetID, location: location)
            }

            // Notify callback for gallery auto-import
            if let assetID = assetID {
                onSaved?(assetID)
            }
        } catch {
            logger.error("❌ Failed to save deferred photo: \(error.localizedDescription)")
        }
    }

    private func unpackPhoto(_ photo: AVCapturePhoto, location: CLLocation?, isLivePhoto: Bool = false) async -> PhotoData? {
        guard var imageData = photo.fileDataRepresentation() else {
            logger.error("Failed to get image data representation")
            return nil
        }

        // ✨ Auto-enhance photo using Apple's CIImage filters (subject-optimized)
        // Skip for Live Photos — re-encoding destroys the MakerApple pairing UUID
        // that links the .heic to its companion .mov file
        if !isLivePhoto, let enhancedData = await autoEnhanceImageData(imageData) {
            imageData = enhancedData
        }

        // 🌍 Write location to EXIF metadata LAST to ensure it's preserved
        // (Auto-enhance may strip GPS metadata, so we add it after all processing)
        if let location = location {
            if let imageDataWithLocation = PhotoMetadataWriter.addLocationMetadata(to: imageData, location: location) {
                imageData = imageDataWithLocation
            }
        }

        // Try to get preview image (thumbnail)
        var thumbnailImage: Image?
        var thumbnailSize = (width: 0, height: 0)

        if let previewCGImage = photo.previewCGImageRepresentation(),
           let metadataOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32,
           let cgImageOrientation = CGImagePropertyOrientation(rawValue: metadataOrientation) {
            let imageOrientation = Image.Orientation(cgImageOrientation)
            thumbnailImage = Image(decorative: previewCGImage, scale: 1, orientation: imageOrientation)
            let previewDimensions = photo.resolvedSettings.previewDimensions
            thumbnailSize = (width: Int(previewDimensions.width), height: Int(previewDimensions.height))
        }

        let photoDimensions = photo.resolvedSettings.photoDimensions
        let imageSize = (width: Int(photoDimensions.width), height: Int(photoDimensions.height))

        return PhotoData(
            thumbnailImage: thumbnailImage,
            thumbnailSize: thumbnailSize,
            imageData: imageData,
            imageSize: imageSize,
            location: location
        )
    }

    /// Auto-enhance image data while preserving original format and metadata
    /// Uses Apple's CIImage auto-adjustment filters for subject-optimized enhancement
    /// - Parameter imageData: Original image data (HEIC/JPEG)
    /// - Returns: Enhanced image data with same format and metadata preserved
    private func autoEnhanceImageData(_ imageData: Data) async -> Data? {
        // Run image processing on background thread to avoid blocking main thread
        return await Task.detached(priority: .userInitiated) {
            // Create UIImage from data (heavy decoding operation)
            guard let uiImage = UIImage(data: imageData) else {
                Self.bgLogger.warning("Failed to create UIImage for auto-enhance")
                return nil
            }

            // Apply auto-enhancement using Apple's native filters (similar to Camera app)
            let enhancedImage = await AutoEnhanceService.shared.enhanceAsync(uiImage)

            // Re-encode with original format and metadata preserved
            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
                return nil
            }

            // Get original image type (HEIC, JPEG, etc.)
            let imageType = CGImageSourceGetType(imageSource) ?? UTType.heic.identifier as CFString

            // Get original metadata (EXIF, GPS, etc.)
            let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]

            // Get CGImage from enhanced UIImage
            guard let enhancedCGImage = enhancedImage.cgImage else {
                return nil
            }

            // Create output data with same format
            let mutableData = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
                return nil
            }

            // Add enhanced image with original metadata
            if let metadata = metadata {
                // Preserve all original metadata including orientation
                CGImageDestinationAddImage(destination, enhancedCGImage, metadata as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, enhancedCGImage, nil)
            }

            // Copy auxiliary data (depth, portrait matte) from source
            await PhotoMetadataWriter.copyAuxiliaryData(from: imageSource, to: destination)

            guard CGImageDestinationFinalize(destination) else {
                return nil
            }

            Self.bgLogger.info("✨ Auto-enhance applied successfully")
            return mutableData as Data
        }.value
    }

    /// Logger for background tasks (nonisolated for Swift 6 compatibility)
    private nonisolated static let bgLogger = Logger(subsystem: Log.subsystem, category: "DataModel.Background")

    @MainActor
    fileprivate func savePhoto(photoData: PhotoData) {
        // ✅ Use background task protection to ensure photo saves even if user quickly exits app
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SavePhoto") {
            // Expiration handler - task is ending, clean up
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        // Capture references to photoCollection and callback
        let collection = self.photoCollection
        let onSaved = self.onPhotoSaved

        // Save photo using high priority background task
        Task.detached(priority: .userInitiated) {
            // Use defer to guarantee cleanup even if exceptions occur
            defer {
                if backgroundTaskID != .invalid {
                    DispatchQueue.main.async {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    }
                }
            }

            do {
                let assetID = try await collection.addImage(photoData.imageData, location: photoData.location)

                // Notify callback for gallery auto-import
                if let assetID = assetID {
                    await MainActor.run {
                        onSaved?(assetID)
                    }
                }
            } catch {
                await logger.error("❌ Failed to add image to photo collection")
            }
        }
    }

    /// Save Live Photo (photo + video paired) using system capture
    fileprivate func saveLivePhoto(photoData: PhotoData, photo: AVCapturePhoto) async {
        // ✅ Use background task protection to ensure Live Photo saves
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "SaveLivePhoto") {
                if backgroundTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    backgroundTaskID = .invalid
                }
            }
        }

        // Capture references
        let collection = await MainActor.run { self.photoCollection }
        let onSaved = await MainActor.run { self.onPhotoSaved }
        let livePhotoManager = await MainActor.run { self.camera.livePhotoManager }
        let photoID = photo.resolvedSettings.uniqueID

        defer {
            if backgroundTaskID != .invalid {
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
            }
        }

        // Wait for movie to complete using async continuation (no polling)
        let completedCapture = await livePhotoManager.waitForCompletedCapture(id: photoID, timeout: 8.0)

        guard let capture = completedCapture else {
            logger.warning("⚠️ Live Photo movie not ready after timeout, saving as regular photo")
            await livePhotoManager.cancelCapture(id: photoID)

            // Fallback: Save as regular photo
            await MainActor.run { [self] in
                savePhoto(photoData: photoData)
            }
            return
        }

        do {
            // Save the Live Photo to the app's album
            let assetID = try await collection.addLivePhoto(
                photoData.imageData,
                movieURL: capture.movieURL,
                location: photoData.location
            )

            // Small delay to ensure Photos library has indexed the new asset
            try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds

            // Notify callback for gallery auto-import
            if let assetID = assetID {
                await MainActor.run {
                    onSaved?(assetID)
                    self.isSavingPhoto = false
                }

                logger.info("✅ Live Photo saved: \(assetID)")
            }

        } catch {
            logger.error("❌ Failed to save Live Photo: \(error.localizedDescription)")

            // Clean up movie file
            try? FileManager.default.removeItem(at: capture.movieURL)

            // Fallback: Save as regular photo
            await MainActor.run { [self] in
                savePhoto(photoData: photoData)
            }
        }
    }

    /// Save a finished recording to the app's album
    /// Called by CameraManager when recording finishes
    @MainActor
    func saveVideo(url: URL, location: CLLocation?) async {
        // ✅ Use background task protection to ensure video saves even if user quickly exits app
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SaveVideo") {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
            }
        }

        let collection = self.photoCollection
        let onSaved = self.onVideoSaved

        defer {
            if backgroundTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }

        do {
            let assetID = try await collection.addVideo(url, location: location)

            // Clean up temp file after successful save
            try? FileManager.default.removeItem(at: url)

            // Notify callback for gallery auto-import
            if let assetID = assetID {
                onSaved?(assetID)
                // Load video thumbnail (unlike photos, videos don't have preview in stream)
                await loadThumbnailFromAsset(assetID: assetID)
            }
        } catch {
            logger.error("❌ Failed to save video: \(error.localizedDescription)")
            // Clean up temp file on error too
            try? FileManager.default.removeItem(at: url)
        }
    }

    func loadPhotos() async {
        guard !isPhotosLoaded else { return }

        let authorized = await AlbumManager.checkAuthorization()
        guard authorized else {
            logger.error("Photo library access was not authorized.")
            return
        }

        do {
            try await self.photoCollection.load()
            self.isPhotosLoaded = true
        } catch let error {
            logger.error("Failed to load photo collection: \(error.localizedDescription)")
            self.isPhotosLoaded = true
        }
    }

    /// Clear the thumbnail back to the placeholder, for an empty album
    @MainActor
    func clearThumbnail() {
        thumbnailImage = nil
        currentThumbnailAssetID = nil
        Task {
            await thumbnailCache.clearCache()
        }
    }

    /// Show the newest photo in the app's album as the thumbnail, or the
    /// placeholder when the album is empty.
    @MainActor
    func loadLatestThumbnail() async {
        // The cached thumbnail may belong to a photo deleted since, e.g. from
        // the Photos app. Drop it so the newest remaining one is shown.
        if let cachedAssetID = currentThumbnailAssetID {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [cachedAssetID], options: nil)
            if fetchResult.count == 0 {
                currentThumbnailAssetID = nil
                thumbnailImage = nil
            }
        }

        if let newest = photoCollection.photoAssets.first?.phAsset {
            await loadThumbnailFromAsset(assetID: newest.localIdentifier)
            return
        }

        clearThumbnail()
    }

    /// Load thumbnail from a specific asset ID
    private func loadThumbnailFromAsset(assetID: String) async {
        // Skip if thumbnail is already loaded for this asset
        if currentThumbnailAssetID == assetID && thumbnailImage != nil {
            return
        }

        // Fetch the PHAsset using the assetID
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let phAsset = fetchResult.firstObject else {
            logger.warning("⚠️ Could not find PHAsset: \(assetID)")
            return
        }

        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions.makeHighQuality()

        // Use higher resolution for better quality on Retina displays
        // UI displays at 50pt, so 150px (3x) provides crisp image
        let scale = UIScreen.main.scale
        let targetSize = CGSize(width: 50 * scale, height: 50 * scale)

        imageManager.requestImage(
            for: phAsset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] uiImage, _ in
            guard let self = self, let uiImage = uiImage else { return }

            Task { @MainActor in
                // Update UI and track current asset ID
                self.thumbnailImage = Image(uiImage: uiImage)
                self.currentThumbnailAssetID = assetID

                // Save to persistent cache
                await self.thumbnailCache.saveThumbnail(uiImage, assetIdentifier: assetID)
            }
        }
    }
}

fileprivate struct PhotoData {
    var thumbnailImage: Image?
    var thumbnailSize: (width: Int, height: Int)
    var imageData: Data
    var imageSize: (width: Int, height: Int)
    var location: CLLocation?     // Photo location info
}

fileprivate let logger = Logger(subsystem: Log.subsystem, category: "DataModel")

