//
//  CaptureAlbum.swift
//  CameraStarter
//
//  The album in the user's photo library that every capture is saved into.
//

import Photos
import CoreLocation
import os.log

/// The album in the user's photo library that every capture is saved into.
///
/// Captures land in the library like any other photo; the album is just the
/// view of the ones this app took. It's created the first time the app runs
/// and found again by its title after that.
@Observable
final class CaptureAlbum: NSObject {
    static let shared = CaptureAlbum(title: "Camera Starter")

    let title: String

    /// The album's newest photo or video. Nil until `prepare()` has run, and
    /// while the album is empty.
    private(set) var newestAsset: PHAsset?

    private var collection: PHAssetCollection?

    /// The album's contents as last fetched, kept to read library changes against.
    private var contents: PHFetchResult<PHAsset>?

    private var isObservingLibrary = false

    enum SaveError: LocalizedError {
        case notPrepared
        case noAssetCreated

        var errorDescription: String? {
            switch self {
            case .notPrepared: "The album isn't ready yet."
            case .noAssetCreated: "The photo library didn't create an asset."
            }
        }
    }

    /// Private so there's one instance, registered with the library for the
    /// life of the app and never needing to unregister.
    private init(title: String) {
        self.title = title
        super.init()
    }

    // MARK: - Access

    /// Whether the app may add to and read the library, asking the first time.
    ///
    /// Limited access counts as no: the album has to be able to see its own
    /// contents to show the newest one.
    static func requestAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        }
        return status == .authorized
    }

    /// Finds the album, creating it on first run, and starts following its
    /// contents. Call once access is granted and before saving anything.
    func prepare() async throws {
        if !isObservingLibrary {
            PHPhotoLibrary.shared().register(self)
            isObservingLibrary = true
        }

        if let existing = Self.album(titled: title) {
            collection = existing
        } else {
            collection = try await Self.createAlbum(titled: title)
        }
        refetchContents()
    }

    // MARK: - Saving

    /// Saves a finished photo.
    @discardableResult
    func savePhoto(_ data: Data, location: CLLocation?) async throws -> String {
        try await save(location: location) { request in
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    /// Saves a Live Photo: the still, and the movie that plays with it.
    /// The movie file is moved into the library, not copied.
    @discardableResult
    func saveLivePhoto(_ data: Data, movieURL: URL, location: CLLocation?) async throws -> String {
        try await save(location: location) { request in
            request.addResource(with: .photo, data: data, options: nil)
            request.addResource(with: .pairedVideo, fileURL: movieURL, options: .movingFile)
        }
    }

    /// Saves a recording. The file is moved into the library, not copied.
    @discardableResult
    func saveVideo(_ url: URL, location: CLLocation?) async throws -> String {
        try await save(location: location) { request in
            request.addResource(with: .video, fileURL: url, options: .movingFile)
        }
    }

    /// Saves a deferred photo's proxy. The system finishes processing it in
    /// the background and swaps the final image into the same asset.
    @discardableResult
    func saveDeferredPhoto(_ proxyData: Data, location: CLLocation?) async throws -> String {
        try await save(location: location) { request in
            request.addResource(with: .photoProxy, data: proxyData, options: nil)
        }
    }

    /// Creates one asset, lets `addResources` fill it, and files it in this
    /// album.
    ///
    /// The location set here is the asset's, which Photos shows and searches
    /// by. It isn't written into the file; callers that want it in the EXIF
    /// too write it there before saving.
    ///
    /// - Returns: The new asset's local identifier.
    private func save(
        location: CLLocation?,
        addResources: @escaping (PHAssetCreationRequest) -> Void
    ) async throws -> String {
        guard let collection else { throw SaveError.notPrepared }

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.location = location
            addResources(request)

            guard let placeholder = request.placeholderForCreatedAsset else { return }
            identifier = placeholder.localIdentifier
            if collection.canPerform(.addContent) {
                PHAssetCollectionChangeRequest(for: collection)?.addAssets([placeholder] as NSArray)
            }
        }

        refetchContents()
        guard let identifier else { throw SaveError.noAssetCreated }
        return identifier
    }

    // MARK: - Contents

    private func refetchContents(_ updated: PHFetchResult<PHAsset>? = nil) {
        guard let collection else { return }
        let fetched = updated ?? PHAsset.fetchAssets(in: collection, options: Self.newestFirst)
        contents = fetched
        newestAsset = fetched.firstObject
    }

    /// Photos and videos, newest first. Live Photos count as photos.
    private static var newestFirst: PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType IN %@",
            [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue]
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return options
    }

    // MARK: - Finding and Creating

    private static func album(titled title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        return PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .any, options: options)
            .firstObject
    }

    private static func createAlbum(titled title: String) async throws -> PHAssetCollection {
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
                .placeholderForCreatedAssetCollection
                .localIdentifier
        }
        guard let identifier,
              let created = PHAssetCollection
                .fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
                .firstObject
        else {
            logger.error("Created album \(title) but couldn't fetch it back")
            throw SaveError.notPrepared
        }
        return created
    }
}

// MARK: - Library Changes

extension CaptureAlbum: PHPhotoLibraryChangeObserver {
    /// Keeps `newestAsset` current when photos are added or deleted anywhere,
    /// including from the Photos app.
    func photoLibraryDidChange(_ change: PHChange) {
        Task { @MainActor in
            guard let contents, let details = change.changeDetails(for: contents) else { return }
            refetchContents(details.fetchResultAfterChanges)
        }
    }
}

private extension PHAssetResourceCreationOptions {
    /// Options that move the source file into the library instead of copying it.
    static var movingFile: PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.shouldMoveFile = true
        return options
    }
}

private let logger = Logger(subsystem: Log.subsystem, category: "CaptureAlbum")
