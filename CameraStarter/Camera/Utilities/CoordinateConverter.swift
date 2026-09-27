//
//  CoordinateConverter.swift
//  CameraStarter
//
//  Centralized coordinate conversion utilities for camera system
//

import AVFoundation
import CoreGraphics

/// Handles all coordinate conversions between different coordinate systems
/// - Vision: Origin at bottom-left, normalized (0-1)
/// - UIKit/SwiftUI: Origin at top-left, points
/// - AVFoundation Device: Origin at top-left, normalized (0-1)
struct CoordinateConverter {

    // MARK: - Vision to Device Coordinates

    /// Converts Vision framework normalized coordinates to AVFoundation device coordinates
    /// Vision: Bottom-left origin, Y increases upward
    /// Device: Top-left origin, Y increases downward
    /// - Parameter visionPoint: Normalized point from Vision (0-1 range)
    /// - Returns: Device-normalized point (0-1 range)
    static func visionToDevice(point visionPoint: CGPoint) -> CGPoint {
        return CGPoint(
            x: visionPoint.x,
            y: 1.0 - visionPoint.y  // Flip Y axis
        )
    }

    /// Converts Vision framework normalized rect to AVFoundation device rect
    /// - Parameter visionRect: Normalized rect from Vision
    /// - Returns: Device-normalized rect
    static func visionToDevice(rect visionRect: CGRect) -> CGRect {
        return CGRect(
            x: visionRect.minX,
            y: 1.0 - visionRect.maxY,  // Flip Y and start from top
            width: visionRect.width,
            height: visionRect.height
        )
    }

    // MARK: - Vision to UI Coordinates

    /// Converts Vision normalized point to UI point in given size
    /// - Parameters:
    ///   - visionPoint: Normalized point from Vision (0-1 range)
    ///   - size: Target UI size
    /// - Returns: Point in UI coordinates
    static func visionToUI(point visionPoint: CGPoint, viewSize size: CGSize) -> CGPoint {
        return CGPoint(
            x: visionPoint.x * size.width,
            y: (1.0 - visionPoint.y) * size.height  // Flip Y axis
        )
    }

    /// Converts Vision normalized rect to UI rect in given size
    /// - Parameters:
    ///   - visionRect: Normalized rect from Vision
    ///   - size: Target UI size
    /// - Returns: Rect in UI coordinates
    static func visionToUI(rect visionRect: CGRect, viewSize size: CGSize) -> CGRect {
        let x = visionRect.minX * size.width
        let y = (1.0 - visionRect.maxY) * size.height  // Flip Y axis
        let width = visionRect.width * size.width
        let height = visionRect.height * size.height

        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - UI to Device Coordinates

    /// Converts UI point to device normalized coordinates using preview layer
    /// - Parameters:
    ///   - uiPoint: Point in UI coordinates
    ///   - previewLayer: The AVCaptureVideoPreviewLayer
    /// - Returns: Device-normalized point (0-1 range), or nil if conversion fails
    static func uiToDevice(point uiPoint: CGPoint, previewLayer: AVCaptureVideoPreviewLayer) -> CGPoint? {
        // AVCaptureVideoPreviewLayer handles video gravity and aspect ratio
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: uiPoint)

        // Validate the converted point is within valid range
        guard devicePoint.x >= 0.0 && devicePoint.x <= 1.0 &&
              devicePoint.y >= 0.0 && devicePoint.y <= 1.0 else {
            return nil
        }

        return devicePoint
    }

    // MARK: - Device to UI Coordinates

    /// Converts device normalized coordinates to UI point using preview layer
    /// - Parameters:
    ///   - devicePoint: Device-normalized point (0-1 range)
    ///   - previewLayer: The AVCaptureVideoPreviewLayer
    /// - Returns: Point in UI coordinates
    static func deviceToUI(point devicePoint: CGPoint, previewLayer: AVCaptureVideoPreviewLayer) -> CGPoint {
        // AVCaptureVideoPreviewLayer handles video gravity and aspect ratio
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: devicePoint)
    }

    /// Converts device normalized rect to UI rect using preview layer
    /// - Parameters:
    ///   - deviceRect: Device-normalized rect (0-1 range)
    ///   - previewLayer: The AVCaptureVideoPreviewLayer
    /// - Returns: Rect in UI coordinates
    static func deviceToUI(rect deviceRect: CGRect, previewLayer: AVCaptureVideoPreviewLayer) -> CGRect {
        return previewLayer.layerRectConverted(fromMetadataOutputRect: deviceRect)
    }

}
