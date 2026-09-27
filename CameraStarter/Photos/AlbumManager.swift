//
//  AlbumManager.swift
//  CameraStarter
//
//  Manages photo album operations including create, load, add and remove photos
//

import Photos
import CoreLocation
import AVFoundation
import os.log

@Observable
class AlbumManager: NSObject {

    var photoAssets: PhotoAssetFetchResult = PhotoAssetFetchResult(PHFetchResult<PHAsset>())

    var identifier: String? {
        assetCollection?.localIdentifier
    }

    var albumName: String?

    var smartAlbumType: PHAssetCollectionSubtype?

    private var assetCollection: PHAssetCollection?

    private var createAlbumIfNotFound = false

    /// Flag to prevent duplicate observer registration
    private var isObserverRegistered = false

    enum AlbumManagerError: LocalizedError {
        case missingAssetCollection
        case missingAlbumName
        case missingLocalIdentifier
        case unableToFindAlbum(String)
        case unableToLoadSmartAlbum(PHAssetCollectionSubtype)
        case addImageError(Error)
        case createAlbumError(Error)
    }

    // MARK: - Shared Instance

    /// Shared manager for the album the camera saves into
    /// Used across the app (Camera, Gallery, Profile) to avoid recreating the manager
    static let shared = AlbumManager(albumNamed: "Camera Starter", createIfNotFound: true)

    init(albumNamed albumName: String, createIfNotFound: Bool = false) {
        self.albumName = albumName
        self.createAlbumIfNotFound = createIfNotFound
        super.init()
    }

    init?(albumWithIdentifier identifier: String) {
        guard let assetCollection = AlbumManager.getAlbum(identifier: identifier) else {
            logger.error("Photo album not found for identifier: \(identifier)")
            return nil
        }
        self.assetCollection = assetCollection
        super.init()
        Task {
            await refreshPhotoAssets()
        }
    }

    init(smartAlbum smartAlbumType: PHAssetCollectionSubtype) {
        self.smartAlbumType = smartAlbumType
        super.init()
    }

    // MARK: - Authorization

    /// Check photo library authorization status
    static func checkAuthorization() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            return true
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        case .denied, .limited, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    deinit {
        if isObserverRegistered {
            let observer = self
            PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        }
    }

    func load() async throws {
        // Register observer only once
        if !isObserverRegistered {
            PHPhotoLibrary.shared().register(self)
            isObserverRegistered = true
        }

        if let smartAlbumType = smartAlbumType {
            if let assetCollection = AlbumManager.getSmartAlbum(subtype: smartAlbumType) {
                self.assetCollection = assetCollection
                await refreshPhotoAssets()
                return
            } else {
                logger.error("Unable to load smart album of type: : \(smartAlbumType.rawValue)")
                throw AlbumManagerError.unableToLoadSmartAlbum(smartAlbumType)
            }
        }

        guard let name = albumName, !name.isEmpty else {
            logger.error("Unable to load an album without a name.")
            throw AlbumManagerError.missingAlbumName
        }

        if let assetCollection = AlbumManager.getAlbum(named: name) {
            self.assetCollection = assetCollection
            await refreshPhotoAssets()
            return
        }

        guard createAlbumIfNotFound else {
            logger.error("Unable to find photo album named: \(name)")
            throw AlbumManagerError.unableToFindAlbum(name)
        }


        if let assetCollection = try? await AlbumManager.createAlbum(named: name) {
            self.assetCollection = assetCollection
            await refreshPhotoAssets()
        }
    }

    /// Add Live Photo to photo library and return the local identifier of the created asset
    /// - Parameters:
    ///   - imageData: Image data (photo component)
    ///   - movieURL: Video file URL (video component)
    ///   - location: Optional location metadata
    /// - Returns: The local identifier of the created PHAsset, or nil if failed
    @discardableResult
    func addLivePhoto(_ imageData: Data, movieURL: URL, location: CLLocation? = nil) async throws -> String? {
        guard let assetCollection = self.assetCollection else {
            throw AlbumManagerError.missingAssetCollection
        }

        var createdAssetID: String?

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()

                // Add location info (if available)
                if let location = location {
                    creationRequest.location = location
                }

                // Add photo resource
                creationRequest.addResource(with: .photo, data: imageData, options: nil)

                // Add paired video resource
                let movieResourceOptions = PHAssetResourceCreationOptions()
                movieResourceOptions.shouldMoveFile = true
                creationRequest.addResource(with: .pairedVideo, fileURL: movieURL, options: movieResourceOptions)

                if let assetPlaceholder = creationRequest.placeholderForCreatedAsset {
                    createdAssetID = assetPlaceholder.localIdentifier

                    // Add to the app's album
                    if let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection), assetCollection.canPerform(.addContent) {
                        let fastEnumeration = NSArray(array: [assetPlaceholder])
                        albumChangeRequest.addAssets(fastEnumeration)
                    }
                }
            }

            await refreshPhotoAssets()

            return createdAssetID

        } catch let error {
            logger.error("Error adding Live Photo to photo library: \(error.localizedDescription)")
            throw AlbumManagerError.addImageError(error)
        }
    }

    /// Add image to photo library and return the local identifier of the created asset
    /// - Parameters:
    ///   - imageData: Image data to save
    ///   - location: Optional location metadata
    /// - Returns: The local identifier of the created PHAsset, or nil if failed
    @discardableResult
    func addImage(_ imageData: Data, location: CLLocation? = nil) async throws -> String? {
        guard let assetCollection = self.assetCollection else {
            throw AlbumManagerError.missingAssetCollection
        }

        var createdAssetID: String?

        do {
            try await PHPhotoLibrary.shared().performChanges {

                let creationRequest = PHAssetCreationRequest.forAsset()

                // Add location info (if available)
                if let location = location {
                    creationRequest.location = location
                }

                if let assetPlaceholder = creationRequest.placeholderForCreatedAsset {
                    createdAssetID = assetPlaceholder.localIdentifier
                    creationRequest.addResource(with: .photo, data: imageData, options: nil)

                    if let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection), assetCollection.canPerform(.addContent) {
                        let fastEnumeration = NSArray(array: [assetPlaceholder])
                        albumChangeRequest.addAssets(fastEnumeration)
                    }
                }
            }

            await refreshPhotoAssets()

            return createdAssetID

        } catch let error {
            logger.error("Error adding image to photo library: \(error.localizedDescription)")
            throw AlbumManagerError.addImageError(error)
        }
    }

    /// Add video to photo library and return the local identifier of the created asset
    /// - Parameters:
    ///   - videoURL: Video file URL
    ///   - location: Optional location metadata
    /// - Returns: The local identifier of the created PHAsset, or nil if failed
    @discardableResult
    func addVideo(_ videoURL: URL, location: CLLocation? = nil) async throws -> String? {
        guard let assetCollection = self.assetCollection else {
            throw AlbumManagerError.missingAssetCollection
        }

        var createdAssetID: String?

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()

                // Add location info (if available)
                if let location = location {
                    creationRequest.location = location
                }

                // Add video resource
                let videoResourceOptions = PHAssetResourceCreationOptions()
                videoResourceOptions.shouldMoveFile = true  // Move file instead of copy for efficiency
                creationRequest.addResource(with: .video, fileURL: videoURL, options: videoResourceOptions)

                if let assetPlaceholder = creationRequest.placeholderForCreatedAsset {
                    createdAssetID = assetPlaceholder.localIdentifier

                    if let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection), assetCollection.canPerform(.addContent) {
                        let fastEnumeration = NSArray(array: [assetPlaceholder])
                        albumChangeRequest.addAssets(fastEnumeration)
                    }
                }
            }

            await refreshPhotoAssets()

            return createdAssetID

        } catch let error {
            logger.error("Error adding video to photo library: \(error.localizedDescription)")
            throw AlbumManagerError.addImageError(error)
        }
    }

    /// Add deferred photo proxy (Deferred Photo Processing)
    /// System will continue processing Deep Fusion / Photonic Engine computational photography in background, auto-updating photo when complete
    /// - Returns: The local identifier of the created PHAsset, or nil if failed
    @discardableResult
    func addDeferredPhoto(_ proxy: AVCaptureDeferredPhotoProxy, location: CLLocation? = nil) async throws -> String? {
        guard let assetCollection = self.assetCollection else {
            throw AlbumManagerError.missingAssetCollection
        }

        // Get proxy file data
        guard var proxyData = proxy.fileDataRepresentation() else {
            logger.error("❌ Failed to get deferred photo proxy data")
            throw AlbumManagerError.addImageError(NSError(domain: "AlbumManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get proxy data"]))
        }

        // Write GPS to EXIF metadata if location available
        // PHAssetCreationRequest.location only sets PHAsset metadata, not EXIF
        if let location = location {
            if let dataWithGPS = PhotoMetadataWriter.addLocationMetadata(to: proxyData, location: location) {
                proxyData = dataWithGPS
            }
        }

        var createdAssetID: String?

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()

                // Also set PHAsset location (for Photos app display)
                if let location = location {
                    creationRequest.location = location
                }

                if let assetPlaceholder = creationRequest.placeholderForCreatedAsset {
                    createdAssetID = assetPlaceholder.localIdentifier
                    // Use .photoProxy resource type, system will auto-complete processing in background
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    creationRequest.addResource(with: .photoProxy, data: proxyData, options: options)

                    if let albumChangeRequest = PHAssetCollectionChangeRequest(for: assetCollection), assetCollection.canPerform(.addContent) {
                        let fastEnumeration = NSArray(array: [assetPlaceholder])
                        albumChangeRequest.addAssets(fastEnumeration)
                    }
                }
            }

            await refreshPhotoAssets()

            return createdAssetID

        } catch let error {
            logger.error("Error adding deferred photo to library: \(error.localizedDescription)")
            throw AlbumManagerError.addImageError(error)
        }
    }

    /// Force refresh photo assets from the photo library
    func refresh() async {
        await refreshPhotoAssets()
    }

    private func refreshPhotoAssets(_ fetchResult: PHFetchResult<PHAsset>? = nil) async {

        var newFetchResult = fetchResult

        if newFetchResult == nil {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            // Fetch photos and videos (image, video, and livePhoto types)
            fetchOptions.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            if let assetCollection = self.assetCollection, let fetchResult = (PHAsset.fetchAssets(in: assetCollection, options: fetchOptions) as AnyObject?) as? PHFetchResult<PHAsset> {
                newFetchResult = fetchResult
            }
        }

        if let newFetchResult = newFetchResult {
            await MainActor.run {
                photoAssets = PhotoAssetFetchResult(newFetchResult)
            }
        }
    }

    private static func getAlbum(identifier: String) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: fetchOptions)
        return collections.firstObject
    }

    private static func getAlbum(named name: String) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", name)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        return collections.firstObject
    }

    private static func getSmartAlbum(subtype: PHAssetCollectionSubtype) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: fetchOptions)
        return collections.firstObject
    }

    private static func createAlbum(named name: String) async throws -> PHAssetCollection? {
        var collectionPlaceholder: PHObjectPlaceholder?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                collectionPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection
            }
        } catch let error {
            logger.error("Error creating album in photo library: \(error.localizedDescription)")
            throw AlbumManagerError.createAlbumError(error)
        }
        guard let collectionIdentifier = collectionPlaceholder?.localIdentifier else {
            throw AlbumManagerError.missingLocalIdentifier
        }
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collectionIdentifier], options: nil)
        return collections.firstObject
    }
}

extension AlbumManager: PHPhotoLibraryChangeObserver {

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let changes = changeInstance.changeDetails(for: self.photoAssets.fetchResult) else { return }
            await self.refreshPhotoAssets(changes.fetchResultAfterChanges)
        }
    }
}

fileprivate let logger = Logger(subsystem: Log.subsystem, category: "AlbumManager")
