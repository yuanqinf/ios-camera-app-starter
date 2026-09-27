//
//  Localization.swift
//  CameraStarter
//

import Foundation

extension String {
    /// This key looked up in Localizable.strings.
    var localized: String {
        NSLocalizedString(self, comment: "")
    }
}
