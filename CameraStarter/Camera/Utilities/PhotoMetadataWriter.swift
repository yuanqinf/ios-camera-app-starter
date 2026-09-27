//
//  PhotoMetadataWriter.swift
//  CameraStarter
//
//  Handles photo EXIF metadata, including GPS location information
//

import Foundation
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import os.log

struct PhotoMetadataWriter {

    private static let logger = Logger(subsystem: Log.subsystem, category: "PhotoMetadataWriter")

    /// Write location information to photo EXIF metadata
    /// - Parameters:
    ///   - imageData: Original photo data
    ///   - location: Location information
    ///   - heading: Optional capture direction (degrees, 0-359)
    /// - Returns: Photo data with GPS EXIF metadata
    static func addLocationMetadata(to imageData: Data, location: CLLocation, heading: CLLocationDirection? = nil) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            logger.error("Failed to create image source from data")
            return nil
        }

        // Get existing metadata
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            logger.error("Failed to copy image metadata")
            return nil
        }

        var mutableMetadata = metadata

        // Create GPS dictionary
        let gpsMetadata = createGPSMetadata(from: location, heading: heading)
        mutableMetadata[kCGImagePropertyGPSDictionary as String] = gpsMetadata

        // Get original image type (preserve HEIC, JPEG, etc.)
        let sourceType = CGImageSourceGetType(imageSource) ?? UTType.heic.identifier as CFString

        // Create output data
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, sourceType, 1, nil) else {
            logger.error("Failed to create image destination")
            return nil
        }

        // Add image and metadata
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, mutableMetadata as CFDictionary)

        // Critical fix: Copy all auxiliary data (depth data, Portrait Effects Matte, etc.)
        // These are required for iOS Photos app Portrait editing features
        copyAuxiliaryData(from: imageSource, to: destination)

        // Finalize write
        guard CGImageDestinationFinalize(destination) else {
            logger.error("Failed to finalize image destination")
            return nil
        }

        let resultData = mutableData as Data

        return resultData
    }

    /// Copy auxiliary data (depth data, Portrait Effects Matte, Semantic Segmentation Mattes)
    /// These are required for iOS Photos app to recognize and edit Portrait photos
    static func copyAuxiliaryData(from source: CGImageSource, to destination: CGImageDestination) {
        // All possible auxiliary data types
        let auxiliaryDataTypes: [CFString] = [
            kCGImageAuxiliaryDataTypeDepth,                    // Depth data
            kCGImageAuxiliaryDataTypeDisparity,                // Disparity data
            kCGImageAuxiliaryDataTypePortraitEffectsMatte,     // Portrait Effects Matte
            kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,   // Skin segmentation
            kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,   // Hair segmentation
            kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,  // Teeth segmentation
            kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte // Glasses segmentation
        ]

        for dataType in auxiliaryDataTypes {
            // Try to read auxiliary data from source image
            if let auxiliaryData = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, dataType) {
                // Write to destination image
                CGImageDestinationAddAuxiliaryDataInfo(destination, dataType, auxiliaryData)
            }
        }
    }

    /// Create GPS metadata dictionary
    private static func createGPSMetadata(from location: CLLocation, heading: CLLocationDirection?) -> [String: Any] {
        var gpsMetadata: [String: Any] = [:]

        // 1. Latitude and longitude
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude

        gpsMetadata[kCGImagePropertyGPSLatitude as String] = abs(latitude)
        gpsMetadata[kCGImagePropertyGPSLatitudeRef as String] = latitude >= 0 ? "N" : "S"

        gpsMetadata[kCGImagePropertyGPSLongitude as String] = abs(longitude)
        gpsMetadata[kCGImagePropertyGPSLongitudeRef as String] = longitude >= 0 ? "E" : "W"

        // 2. Altitude (if available)
        if location.altitude != 0 {
            gpsMetadata[kCGImagePropertyGPSAltitude as String] = abs(location.altitude)
            gpsMetadata[kCGImagePropertyGPSAltitudeRef as String] = location.altitude >= 0 ? 0 : 1
        }

        // 3. GPS timestamp
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy:MM:dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        gpsMetadata[kCGImagePropertyGPSDateStamp as String] = dateFormatter.string(from: location.timestamp)

        dateFormatter.dateFormat = "HH:mm:ss.SS"
        gpsMetadata[kCGImagePropertyGPSTimeStamp as String] = dateFormatter.string(from: location.timestamp)

        // 4. Horizontal accuracy (DOP - Dilution of Precision)
        if location.horizontalAccuracy >= 0 {
            // Convert to DOP value (better accuracy = smaller DOP)
            let hdop = location.horizontalAccuracy / 5.0 // Rough conversion
            gpsMetadata[kCGImagePropertyGPSHPositioningError as String] = location.horizontalAccuracy
            gpsMetadata[kCGImagePropertyGPSDOP as String] = hdop
        }

        // 5. Speed (if available)
        if location.speed >= 0 {
            gpsMetadata[kCGImagePropertyGPSSpeed as String] = location.speed
            gpsMetadata[kCGImagePropertyGPSSpeedRef as String] = "K" // km/h
        }

        // 6. Capture direction/heading (if provided)
        if let heading = heading, heading >= 0 {
            gpsMetadata[kCGImagePropertyGPSImgDirection as String] = heading
            gpsMetadata[kCGImagePropertyGPSImgDirectionRef as String] = "T" // True North
        } else if location.course >= 0 {
            // If heading not provided, use device movement direction
            gpsMetadata[kCGImagePropertyGPSTrack as String] = location.course
            gpsMetadata[kCGImagePropertyGPSTrackRef as String] = "T"
        }

        // 7. Satellite information (marked as GPS)
        gpsMetadata[kCGImagePropertyGPSMeasureMode as String] = "3" // 3D measurement

        // 8. Processing status (actual measurement)
        gpsMetadata[kCGImagePropertyGPSStatus as String] = "A" // A = Measurement Active

        // 9. Map datum (WGS-84, GPS standard)
        gpsMetadata[kCGImagePropertyGPSMapDatum as String] = "WGS-84"

        return gpsMetadata
    }
}

