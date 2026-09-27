//
//  PhotoAsset.swift
//  CameraStarter
//
//  Created by Yuanqin Fan on 11/10/25.
//

import Photos
import os.log

struct PhotoAsset: Identifiable {
    var id: String { identifier }
    var identifier: String = UUID().uuidString
    var index: Int?
    var phAsset: PHAsset?

    typealias MediaType = PHAssetMediaType

    var isFavorite: Bool {
        phAsset?.isFavorite ?? false
    }

    var isLivePhoto: Bool {
        phAsset?.mediaSubtypes.contains(.photoLive) ?? false
    }

    var mediaType: MediaType {
        phAsset?.mediaType ?? .unknown
    }

    var isVideo: Bool {
        phAsset?.mediaType == .video
    }

    /// Video duration in seconds (0 for non-video assets)
    var videoDuration: TimeInterval {
        phAsset?.duration ?? 0
    }

    /// Formatted video duration string (e.g., "0:15", "1:30")
    var videoDurationFormatted: String {
        guard isVideo else { return "" }
        let duration = Int(videoDuration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var accessibilityLabel: String {
        "Photo\(isFavorite ? ", Favorite" : "")"
    }

    init(phAsset: PHAsset, index: Int?) {
        self.phAsset = phAsset
        self.index = index
        self.identifier = phAsset.localIdentifier
    }

    init(identifier: String) {
        self.identifier = identifier
        let fetchedAssets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        self.phAsset = fetchedAssets.firstObject
    }

    /// Set favorite status and return updated PhotoAsset
    /// - Returns: Updated PhotoAsset with refreshed PHAsset, or nil if failed
    @discardableResult
    mutating func setIsFavorite(_ isFavorite: Bool) async -> Bool {
        guard let phAsset = phAsset else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: phAsset)
                request.isFavorite = isFavorite
            }
            // Refresh the PHAsset to get updated isFavorite value
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            if let refreshedAsset = fetchResult.firstObject {
                self.phAsset = refreshedAsset
            }
            return true
        } catch (let error) {
            logger.error("Failed to change isFavorite: \(error.localizedDescription)")
            return false
        }
    }

    /// Delete the photo asset from the photo library
    /// - Returns: true if deletion was successful, false if user cancelled or an error occurred
    func delete() async -> Bool {
        guard let phAsset = phAsset else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([phAsset] as NSArray)
            }
            return true
        } catch (let error) {
            logger.error("Failed to delete photo: \(error.localizedDescription)")
            return false
        }
    }
}

extension PhotoAsset: Equatable {
    static func ==(lhs: PhotoAsset, rhs: PhotoAsset) -> Bool {
        (lhs.identifier == rhs.identifier) && (lhs.isFavorite == rhs.isFavorite)
    }
}

extension PhotoAsset: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

fileprivate let logger = Logger(subsystem: Log.subsystem, category: "PhotoAsset")
