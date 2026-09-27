//
//  ThumbnailCache.swift
//  CameraStarter
//
//  Created by Claude on 11/27/25.
//  Persistent cache for the first photo thumbnail
//

import SwiftUI
import UIKit
import os.log

/// Manages persistent caching of the most recent photo thumbnail
/// Ensures the camera UI always shows a thumbnail immediately on launch
actor ThumbnailCache {
    private static let cacheKey = "lastPhotoThumbnail"
    private static let assetIdentifierKey = "lastPhotoAssetIdentifier"

    private let logger = Logger(subsystem: Log.subsystem, category: "ThumbnailCache")

    /// Load cached thumbnail synchronously (for immediate display)
    nonisolated func loadCachedThumbnail() -> Image? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let uiImage = UIImage(data: data) else {
            return nil
        }

        return Image(uiImage: uiImage)
    }

    /// Save thumbnail to persistent cache
    func saveThumbnail(_ image: UIImage, assetIdentifier: String) async {
        // Compress to JPEG for smaller storage (quality 0.8 is good balance)
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            logger.error("Failed to compress thumbnail to JPEG")
            return
        }

        // Save to UserDefaults on main thread
        await MainActor.run {
            UserDefaults.standard.set(jpegData, forKey: Self.cacheKey)
            UserDefaults.standard.set(assetIdentifier, forKey: Self.assetIdentifierKey)
        }
    }

    /// Get the cached asset identifier (to check if cache is still valid)
    nonisolated func getCachedAssetIdentifier() -> String? {
        return UserDefaults.standard.string(forKey: Self.assetIdentifierKey)
    }

    func clearCache() async {
        await MainActor.run {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
            UserDefaults.standard.removeObject(forKey: Self.assetIdentifierKey)
        }
    }
}
