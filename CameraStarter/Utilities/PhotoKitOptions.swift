//
//  PhotoKitOptions.swift
//  CameraStarter
//

import Photos

extension PHImageRequestOptions {
    /// Full quality, resized quickly, fetched from iCloud when not on device.
    nonisolated static func makeHighQuality() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }
}
