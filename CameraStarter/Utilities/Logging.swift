//
//  Logging.swift
//  CameraStarter
//

import Foundation

enum Log {
    /// The subsystem every Logger in the app files under, so Console can
    /// filter to this app alone. Taken from the bundle identifier, which
    /// means a fork's logs follow its own identifier without an edit.
    nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "CameraStarter"
}
