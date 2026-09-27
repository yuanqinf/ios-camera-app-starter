//
//  CaptureMode.swift
//  CameraStarter
//
//  Capture mode definition
//  Photo: Normal photo mode
//  Portrait: Portrait mode (background blur)
//

import Foundation

/// Capture mode
enum CaptureMode: String, CaseIterable {
    case photo = "PHOTO"
    case portrait = "PORTRAIT"

    var displayName: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .photo:
            return "camera"
        case .portrait:
            return "person.crop.circle"
        }
    }

    /// Whether depth data is required
    var requiresDepthData: Bool {
        switch self {
        case .photo:
            return false
        case .portrait:
            return true
        }
    }

    /// Refocus trigger threshold (refocus when subject moves beyond this ratio)
    var refocusThreshold: CGFloat {
        switch self {
        case .photo:
            return 0.08  // 8% - balanced
        case .portrait:
            return 0.12  // 12% - more stable, avoid frequent focus jumps during blur
        }
    }
}
