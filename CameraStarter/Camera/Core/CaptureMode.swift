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
}
