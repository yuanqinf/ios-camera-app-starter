//
//  LocationManager.swift
//  CameraStarter
//
//  Location manager - Handles location retrieval for adding geotags to photos
//

import CoreLocation
import os.log

@MainActor
@Observable
final class LocationManager: NSObject {

    // MARK: - Public Properties

    /// Current location
    private(set) var currentLocation: CLLocation?

    /// Authorization status
    private(set) var authorizationStatus: CLAuthorizationStatus

    // MARK: - Private Properties

    private let locationManager: CLLocationManager
    private let logger = Logger(subsystem: Log.subsystem, category: "LocationManager")

    // MARK: - Initialization

    override init() {
        self.locationManager = CLLocationManager()
        self.authorizationStatus = locationManager.authorizationStatus

        super.init()

        locationManager.delegate = self
        // Use best accuracy for photo geotags (required for Photos app to show map)
        // Lower accuracy (100m) causes Photos to show "Add a Location" instead of map
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10 // Update when moved 10+ meters

        // Don't pause automatic updates - ensures location is always available for photos
        // Battery impact is minimal since we use distanceFilter = 10m
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    // MARK: - Public Methods

    /// Start location updates if already authorized (does not prompt user)
    /// Location is optional — only used for photo geotagging
    func requestAuthorization() {
        let status = locationManager.authorizationStatus

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // Start location updates to warm up cache for photo geotagging
            startUpdatingLocation()
        case .notDetermined, .denied, .restricted:
            // Don't prompt — location is optional for camera
            logger.info("Location not authorized (status: \(status.rawValue)), skipping")
        @unknown default:
            break
        }
    }

    /// Explicitly request location permission (called from permission UI)
    func requestPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// Start updating location
    func startUpdatingLocation() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logger.warning("Cannot start location updates - not authorized")
            return
        }

        locationManager.startUpdatingLocation()
    }

    /// Stop updating location
    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }

    /// Request instant location update (used when taking photos)
    /// Returns the latest location, or cached location if unavailable
    /// Optimized for zero-latency return when possible
    func requestInstantLocation() async -> CLLocation? {
        // Fast path: Return cached location if available (any age)
        // For photos, having a location is better than having none
        // User typically doesn't move far between photos
        if let location = currentLocation {
            // If location is old (>60s), trigger background refresh for next photo
            if abs(location.timestamp.timeIntervalSinceNow) > 60 {
                locationManager.requestLocation()
            }
            return location
        }

        // No cached location - try to request one
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            logger.warning("Cannot request location - not authorized")
            return nil
        }

        // Ensure location updates are running
        locationManager.startUpdatingLocation()

        // Use requestLocation() to get one-time location with timeout
        return await withCheckedContinuation { continuation in
            let requestId = UUID()

            // Set timeout (3 seconds)
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)

                Task { @MainActor in
                    if self.pendingLocationRequest?.id == requestId {
                        self.pendingLocationRequest = nil
                        continuation.resume(returning: self.currentLocation)
                    }
                }
            }

            // Save continuation and request location
            self.pendingLocationRequest = (id: requestId, continuation: continuation)
            self.locationManager.requestLocation()
        }
    }

    /// Resume location updates (call when app becomes active)
    func resumeLocationUpdates() {
        guard authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways else {
            return
        }
        locationManager.startUpdatingLocation()
    }

    // MARK: - Private Properties (Instant Location Request)

    private var pendingLocationRequest: (id: UUID, continuation: CheckedContinuation<CLLocation?, Never>)?
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            self.currentLocation = location

            // If there's a pending instant location request, return immediately
            if let pending = self.pendingLocationRequest {
                pending.continuation.resume(returning: location)
                self.pendingLocationRequest = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // If there's a pending instant location request, return cached location
            if let pending = self.pendingLocationRequest {
                pending.continuation.resume(returning: self.currentLocation)
                self.pendingLocationRequest = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus

        Task { @MainActor in
            self.authorizationStatus = status

            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                // Start location updates to warm up cache for photo geotagging
                self.startUpdatingLocation()
            case .denied, .restricted:
                self.stopUpdatingLocation()
                self.currentLocation = nil
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }
}

