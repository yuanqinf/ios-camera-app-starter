//
//  DeferredPhotoGPSRestorer.swift
//  CameraStarter
//
//  Restores GPS metadata after iOS Deferred Photo Processing completes.
//  When using isAutoDeferredPhotoDeliveryEnabled, the system replaces the photo
//  file during background processing, which loses GPS EXIF data. This service
//  monitors processing completion and restores the location metadata.
//

import Photos
import CoreLocation
import UIKit
import os.log

// MARK: - Pending GPS Restoration Model

/// Codable model for persisting pending GPS restorations across app launches
private struct PendingGPSRestoration: Codable {
    let assetID: String
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let timestamp: Date

    init(assetID: String, location: CLLocation) {
        self.assetID = assetID
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.verticalAccuracy = location.verticalAccuracy
        self.timestamp = location.timestamp
    }

    var location: CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            timestamp: timestamp
        )
    }
}

// MARK: - Deferred Photo GPS Restorer

/// Singleton service that restores GPS metadata to photos after Deferred Photo Processing
final class DeferredPhotoGPSRestorer {

    static let shared = DeferredPhotoGPSRestorer()

    // MARK: - Configuration

    private enum Config {
        static let persistenceKey = "pendingGPSRestorations"
        static let maxWaitTime: TimeInterval = 30
        static let checkInterval: TimeInterval = 0.5
        static let postProcessingDelay: TimeInterval = 2.0
        static let alreadyCompleteDelay: TimeInterval = 0.5
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: Log.subsystem, category: "GPSRestorer")
    private let lock = NSLock()

    private var pendingRestorations: [String: CLLocation] = [:]
    private var processingAssets: Set<String> = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Whether there are pending GPS restorations
    var hasPendingRestorations: Bool {
        lock.withLock { !pendingRestorations.isEmpty }
    }

    // MARK: - Initialization

    private init() {
        loadPersistedRestorations()
    }

    // MARK: - Public API

    /// Schedule GPS restoration for a deferred photo
    func scheduleRestoration(for assetID: String, location: CLLocation) {
        lock.withLock {
            pendingRestorations[assetID] = location
            processingAssets.insert(assetID)
        }

        persistPendingRestorations()

        Task { await processRestoration(assetID: assetID, location: location) }
    }

    /// Resume any pending restorations (call on app launch/foreground)
    func resumePendingRestorations() {
        let assetsToProcess: [(String, CLLocation)] = lock.withLock {
            pendingRestorations.compactMap { assetID, location in
                guard !processingAssets.contains(assetID) else { return nil }
                processingAssets.insert(assetID)
                return (assetID, location)
            }
        }

        for (assetID, location) in assetsToProcess {
            Task { await processRestoration(assetID: assetID, location: location) }
        }
    }

    // MARK: - Background Task Management

    /// Request background execution time for GPS restoration
    func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "GPSRestoration") { [weak self] in
            self?.endBackgroundTask()
        }

    }

    /// End background task when GPS restoration completes
    func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Processing

    private func processRestoration(assetID: String, location: CLLocation) async {
        await waitForProcessingComplete(assetID: assetID)
        await restoreGPS(assetID: assetID, location: location)

        let shouldEndBackgroundTask: Bool = lock.withLock {
            pendingRestorations.removeValue(forKey: assetID)
            processingAssets.remove(assetID)
            return pendingRestorations.isEmpty
        }

        persistPendingRestorations()

        if shouldEndBackgroundTask {
            endBackgroundTask()
        }
    }

    private func waitForProcessingComplete(assetID: String) async {
        let hasProxy = await checkHasPhotoProxy(assetID: assetID)

        if hasProxy {
            let startTime = Date()

            while Date().timeIntervalSince(startTime) < Config.maxWaitTime {
                try? await Task.sleep(for: .seconds(Config.checkInterval))

                if await !checkHasPhotoProxy(assetID: assetID) {
                    break
                }
            }

            try? await Task.sleep(for: .seconds(Config.postProcessingDelay))
        } else {
            try? await Task.sleep(for: .seconds(Config.alreadyCompleteDelay))
        }
    }

    private func checkHasPhotoProxy(assetID: String) async -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetchResult.firstObject else { return false }

        return PHAssetResource.assetResources(for: asset).contains { $0.type == .photoProxy }
    }

    private func restoreGPS(assetID: String, location: CLLocation) async {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetchResult.firstObject else {
            logger.error("Asset not found: \(assetID)")
            return
        }

        // PHAsset.location is the only writable location field for existing assets;
        // PhotoKit doesn't allow rewriting EXIF in-place. Set it directly — that's
        // enough for Photos app's map view and info pane.
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).location = location
            }
        } catch {
            logger.error("Failed to set PHAsset.location for \(assetID): \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func persistPendingRestorations() {
        let pending: [String: CLLocation] = lock.withLock { pendingRestorations }
        let restorations = pending.map { PendingGPSRestoration(assetID: $0.key, location: $0.value) }

        guard let data = try? JSONEncoder().encode(restorations) else {
            logger.error("❌ Failed to encode GPS restorations")
            return
        }

        UserDefaults.standard.set(data, forKey: Config.persistenceKey)
    }

    private func loadPersistedRestorations() {
        guard let data = UserDefaults.standard.data(forKey: Config.persistenceKey),
              let restorations = try? JSONDecoder().decode([PendingGPSRestoration].self, from: data) else {
            return
        }

        lock.withLock {
            for restoration in restorations {
                pendingRestorations[restoration.assetID] = restoration.location
            }
        }
    }
}
