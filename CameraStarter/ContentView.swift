//
//  ContentView.swift
//  CameraStarter
//

import SwiftUI

/// The whole app is the camera.
struct ContentView: View {
    /// Owned here so the camera session outlives any view rebuild below.
    @State private var model = DataModel()

    /// False while the permission screen is up, true once the preview is live.
    @State private var isCameraReady = false

    var body: some View {
        CameraView(model: model, isCameraReady: $isCameraReady)
            // Dark once the viewfinder shows, so the system chrome around it
            // matches; the permission screen keeps the user's own appearance.
            .preferredColorScheme(isCameraReady ? .dark : nil)
    }
}
