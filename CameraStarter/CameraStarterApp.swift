//
//  CameraStarterApp.swift
//  CameraStarter
//

import SwiftUI

@main
struct CameraStarterApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let gpsRestorer = DeferredPhotoGPSRestorer.shared
            switch phase {
            case .active:
                // Deferred photos lose their EXIF location when the system
                // finishes processing them. Pick up any still owed it from a
                // previous run, including one the system ended mid-wait.
                gpsRestorer.resumePendingRestorations()
            case .background:
                // Ask for time to finish the ones in progress.
                if gpsRestorer.hasPendingRestorations {
                    gpsRestorer.beginBackgroundTask()
                }
            default:
                break
            }
        }
    }
}
