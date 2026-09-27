//
//  CameraModel.swift
//  CameraStarter
//
//  Connects the camera to the photo library: saves each capture into the
//  app's album and keeps the thumbnail on the newest one.
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
final class CameraModel {
    let camera = CameraManager()
    let timer = CameraTimerManager()

    /// The newest capture, for the thumbnail button. Nil shows the placeholder.
    private(set) var thumbnail: Image?

    /// Called as each photo reaches the thumbnail, ahead of it being saved.
    var onCapture: (() -> Void)?

    private let album = CaptureAlbum.shared
    private let thumbnailCache = ThumbnailCache()

    /// The saved asset `thumbnail` is drawn from. Lags behind a capture that is
    /// on screen but still saving.
    private var thumbnailAssetID: String?

    private var isAlbumReady = false

    /// The loops reading the camera's streams, cancelled with the model.
    private var streamTasks: [Task<Void, Never>] = []

    init() {
        // Last session's thumbnail, so the button isn't empty while the
        // library loads.
        thumbnail = thumbnailCache.loadCachedThumbnail()
        thumbnailAssetID = thumbnailCache.getCachedAssetIdentifier()

        streamTasks = [
            Task { await receivePhotos() },
            Task { await receiveDeferredPhotos() },
            Task { await receiveVideos() },
        ]
    }

    deinit {
        for task in streamTasks {
            task.cancel()
        }
    }

    // MARK: - Album

    /// Gets the album ready to save into, asking for library access the first
    /// time. Does nothing once it has run.
    func prepareAlbum() async {
        guard !isAlbumReady else { return }

        guard await CaptureAlbum.requestAccess() else {
            logger.error("Photo library access was not granted")
            return
        }

        do {
            try await album.prepare()
        } catch {
            logger.error("Couldn't prepare the album: \(error.localizedDescription)")
        }
        isAlbumReady = true
    }

    // MARK: - Receiving Captures

    private func receivePhotos() async {
        for await (photo, location) in camera.photoStream {
            show(photo)
            Task(priority: .userInitiated) {
                await save(photo, location: location)
            }
        }
    }

    /// Deferred photos: the system finishes Deep Fusion and the Photonic
    /// Engine's processing in the background, after the proxy is saved.
    private func receiveDeferredPhotos() async {
        for await (proxy, location) in camera.deferredPhotoStream {
            show(proxy)
            Task(priority: .userInitiated) {
                await saveDeferred(proxy, location: location)
            }
        }
    }

    private func receiveVideos() async {
        for await (url, location) in camera.videoStream {
            await saveVideo(url, location: location)
        }
    }

    /// Puts a capture in the thumbnail the moment it arrives, without waiting
    /// for it to be processed and saved.
    private func show(_ photo: AVCapturePhoto) {
        guard let image = photo.thumbnailImage else { return }
        thumbnail = image
        onCapture?()
    }

    // MARK: - Saving

    private func save(_ photo: AVCapturePhoto, location: CLLocation?) async {
        guard var data = photo.fileDataRepresentation() else {
            logger.error("Captured photo has no file data")
            return
        }

        // A Live Photo's still is tied to its movie by an identifier in the
        // file's metadata, which re-encoding would drop, so it isn't enhanced.
        let isLivePhoto = photo.resolvedSettings.livePhotoMovieDimensions.width > 0
        let captureID = photo.resolvedSettings.uniqueID

        await withBackgroundTime("SavePhoto") {
            if !isLivePhoto, let enhanced = await Self.autoEnhanced(data) {
                data = enhanced
            }
            // Written last: enhancing re-encodes the file and would drop it.
            if let location, let tagged = PhotoMetadataWriter.addLocationMetadata(to: data, location: location) {
                data = tagged
            }

            if isLivePhoto, await saveLivePhoto(data, captureID: captureID, location: location) {
                return
            }

            do {
                thumbnailAssetID = try await album.savePhoto(data, location: location)
            } catch {
                logger.error("Failed to save photo: \(error.localizedDescription)")
            }
        }
    }

    /// Saves a Live Photo once its movie has been written.
    ///
    /// - Returns: False if it couldn't be saved as one, for the caller to save
    ///   the still on its own.
    private func saveLivePhoto(_ data: Data, captureID: Int64, location: CLLocation?) async -> Bool {
        let livePhotos = camera.livePhotoManager

        guard let capture = await livePhotos.waitForCompletedCapture(id: captureID, timeout: 8) else {
            logger.warning("Live Photo movie wasn't ready in time; saving the still alone")
            await livePhotos.cancelCapture(id: captureID)
            return false
        }

        do {
            thumbnailAssetID = try await album.saveLivePhoto(data, movieURL: capture.movieURL, location: location)
            return true
        } catch {
            logger.error("Failed to save Live Photo: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: capture.movieURL)
            return false
        }
    }

    private func saveDeferred(_ proxy: AVCaptureDeferredPhotoProxy, location: CLLocation?) async {
        guard var data = proxy.fileDataRepresentation() else {
            logger.error("Deferred photo proxy has no file data")
            return
        }

        // The asset's location is what Photos shows; this puts it in the file
        // too, for wherever the photo goes next.
        if let location, let tagged = PhotoMetadataWriter.addLocationMetadata(to: data, location: location) {
            data = tagged
        }

        await withBackgroundTime("SaveDeferredPhoto") {
            do {
                let assetID = try await album.saveDeferredPhoto(data, location: location)
                thumbnailAssetID = assetID

                // Processing swaps in a new file, and the EXIF location goes
                // with the old one, so it's written again once that's done.
                if let location {
                    DeferredPhotoGPSRestorer.shared.scheduleRestoration(for: assetID, location: location)
                }
            } catch {
                logger.error("Failed to save deferred photo: \(error.localizedDescription)")
            }
        }
    }

    private func saveVideo(_ url: URL, location: CLLocation?) async {
        await withBackgroundTime("SaveVideo") {
            do {
                let assetID = try await album.saveVideo(url, location: location)
                // Recordings don't arrive with a preview the way photos do, so
                // the thumbnail is drawn from the saved asset instead.
                loadThumbnail(assetID: assetID)
            } catch {
                logger.error("Failed to save video: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Runs `work` with extra time requested from the system, so a save that
    /// starts just before the user leaves the app still finishes.
    private func withBackgroundTime(_ name: String, _ work: () async -> Void) async {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }

        await work()

        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }

    // MARK: - Enhancing

    /// The photo with Core Image's auto-adjustments applied, re-encoded in its
    /// original format with its metadata and depth data carried over. Nil if
    /// any step fails, for the caller to keep the original.
    private nonisolated static func autoEnhanced(_ imageData: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            guard let uiImage = UIImage(data: imageData) else {
                Self.bgLogger.warning("Failed to create UIImage for auto-enhance")
                return nil
            }

            let enhancedImage = await AutoEnhanceService.shared.enhanceAsync(uiImage)

            guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let enhancedCGImage = enhancedImage.cgImage else {
                return nil
            }

            // Same container as the original (HEIC, JPEG, ...), same EXIF
            let imageType = CGImageSourceGetType(imageSource) ?? UTType.heic.identifier as CFString
            let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, imageType, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, enhancedCGImage, metadata)

            // Depth and the portrait matte, so Portrait photos stay editable
            await PhotoMetadataWriter.copyAuxiliaryData(from: imageSource, to: destination)

            guard CGImageDestinationFinalize(destination) else {
                return nil
            }

            Self.bgLogger.info("Auto-enhance applied successfully")
            return output as Data
        }.value
    }

    /// Logger for background tasks (nonisolated for Swift 6 compatibility)
    private nonisolated static let bgLogger = Logger(subsystem: Log.subsystem, category: "CameraModel.Background")

    // MARK: - Thumbnail

    /// Shows the album's newest photo or video, or the placeholder when the
    /// album is empty.
    func loadLatestThumbnail() async {
        // The cached thumbnail may belong to a photo deleted since, e.g. from
        // the Photos app. Drop it so the newest remaining one is shown.
        if let cachedID = thumbnailAssetID,
           PHAsset.fetchAssets(withLocalIdentifiers: [cachedID], options: nil).count == 0 {
            thumbnailAssetID = nil
            thumbnail = nil
        }

        guard let newest = album.newestAsset else {
            clearThumbnail()
            return
        }
        loadThumbnail(assetID: newest.localIdentifier)
    }

    /// Back to the placeholder, for an empty album.
    private func clearThumbnail() {
        thumbnail = nil
        thumbnailAssetID = nil
        Task {
            await thumbnailCache.clearCache()
        }
    }

    /// Draws the thumbnail from a saved asset, and caches it for next launch.
    private func loadThumbnail(assetID: String) {
        guard assetID != thumbnailAssetID || thumbnail == nil else { return }

        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            logger.warning("Could not find PHAsset: \(assetID)")
            return
        }

        // The button is 50pt square; request it at screen scale to stay crisp.
        let side = 50 * UIScreen.main.scale
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: .makeHighQuality()
        ) { [weak self] uiImage, _ in
            guard let self, let uiImage else { return }

            Task { @MainActor in
                self.thumbnail = Image(uiImage: uiImage)
                self.thumbnailAssetID = assetID
                await self.thumbnailCache.saveThumbnail(uiImage, assetIdentifier: assetID)
            }
        }
    }
}

// MARK: - Drawing a Capture

private extension AVCapturePhoto {
    /// The capture at thumbnail size: the camera's preview image when it made
    /// one, which costs far less than decoding the full photo.
    var thumbnailImage: Image? {
        guard let cgImage = previewCGImageRepresentation() ?? cgImageRepresentation() else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1, orientation: displayOrientation)
    }

    /// Which way up to draw the capture's pixels. They come off the sensor
    /// unrotated, with the device's orientation recorded in the metadata.
    var displayOrientation: Image.Orientation {
        guard let value = metadata[kCGImagePropertyOrientation as String] as? UInt32,
              let exif = CGImagePropertyOrientation(rawValue: value) else {
            return .up
        }
        // The two enums name the same eight orientations.
        return switch exif {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        }
    }
}

private let logger = Logger(subsystem: Log.subsystem, category: "CameraModel")
