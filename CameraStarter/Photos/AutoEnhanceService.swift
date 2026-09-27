//
//  AutoEnhanceService.swift
//  CameraStarter
//
//  Auto-enhancement service using Apple's CIImage auto-adjustment filters
//  Mimics iOS Photos app's one-click "Auto" enhancement feature
//

import CoreImage
import UIKit
import os.log

/// Service for automatic image enhancement using Apple's CIImage auto-adjustment
final class AutoEnhanceService {

    // MARK: - Singleton

    static let shared = AutoEnhanceService()

    // MARK: - Properties

    private let logger = Logger(subsystem: Log.subsystem, category: "AutoEnhance")

    /// GPU-accelerated CIContext for better performance
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,  // Use GPU acceleration
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .highQualityDownsample: true
        ]
        return CIContext(options: options)
    }()

    private init() {}

    // MARK: - Public Methods

    /// Apply auto-enhancement filters to an image
    /// Uses Apple's CIImage.autoAdjustmentFilters() which analyzes the image
    /// and returns pre-configured filters similar to native Camera app
    /// - Parameters:
    ///   - image: Original UIImage
    /// - Returns: Enhanced UIImage, or original if enhancement fails
    func enhance(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            logger.warning("Failed to create CIImage from UIImage")
            return image
        }

        // Get auto-adjustment filters from Apple's analysis
        // Skip red-eye correction for subject photos (subjects have different eye reflections)
        let filterOptions: [CIImageAutoAdjustmentOption: Any] = [
            .enhance: true,
            .redEye: false
        ]

        let filters = ciImage.autoAdjustmentFilters(options: filterOptions)

        // Apply filters sequentially
        var outputImage = ciImage
        for filter in filters {
            filter.setValue(outputImage, forKey: kCIInputImageKey)
            if let result = filter.outputImage {
                outputImage = result
            }
        }

        // Render to CGImage
        guard let cgImage = context.createCGImage(
            outputImage,
            from: outputImage.extent
        ) else {
            logger.error("Failed to create CGImage from enhanced CIImage")
            return image
        }

        return UIImage(
            cgImage: cgImage,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }

    /// Async version for UI responsiveness
    /// - Parameter image: Original UIImage
    /// - Returns: Enhanced UIImage
    func enhanceAsync(_ image: UIImage) async -> UIImage {
        return await Task.detached(priority: .userInitiated) { [self] in
            return self.enhance(image)
        }.value
    }
}


