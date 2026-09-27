//
//  CameraPermissionView.swift
//  CameraStarter
//
//  Asks for camera, location and microphone access, in the style of Settings
//

import SwiftUI
import AVFoundation
import CoreLocation

/// Camera permission view with card-style permission UI
struct CameraPermissionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraStatus: AVAuthorizationStatus = .notDetermined
    @State private var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @State private var locationStatus: CLAuthorizationStatus = .notDetermined
    @State private var locationManager = CameraLocationPermissionManager()
    @State private var appearAnimation = false

    var onComplete: () -> Void

    /// Whether camera access is granted (required)
    private var isCameraGranted: Bool {
        cameraStatus == .authorized
    }

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Illustration
                illustrationSection
                    .padding(.bottom, 32)
                    .scaleEffect(appearAnimation ? 1 : 0.8)
                    .opacity(appearAnimation ? 1 : 0)

                // Title and description
                textSection
                    .padding(.horizontal, 28)
                    .padding(.bottom, 32)
                    .opacity(appearAnimation ? 1 : 0)
                    .offset(y: appearAnimation ? 0 : 20)

                // Permission cards
                permissionCards
                    .padding(.horizontal, 20)
                    .opacity(appearAnimation ? 1 : 0)
                    .offset(y: appearAnimation ? 0 : 30)

                Spacer()

                // Continue button (only when camera is granted)
                if isCameraGranted {
                    continueButton
                        .padding(.horizontal, 24)
                        .padding(.bottom, 50)
                        .opacity(appearAnimation ? 1 : 0)
                        .offset(y: appearAnimation ? 0 : 20)
                }
            }
        }
        .onAppear {
            checkAllPermissions()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                appearAnimation = true
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                checkAllPermissions()
            }
        }
        .onChange(of: locationManager.authorizationStatus) { _, _ in
            locationStatus = locationManager.authorizationStatus
        }
    }

    // MARK: - Illustration

    /// A large symbol in the accent color, the way Apple's own welcome
    /// screens open. Viewfinder rather than camera.fill, which the first row
    /// already shows.
    private var illustrationSection: some View {
        Image(systemName: "camera.viewfinder")
            .font(.system(size: 88, weight: .regular))
            .foregroundStyle(.tint)
            // Decorative: the text under it says what the screen is for.
            .accessibilityHidden(true)
    }

    // MARK: - Text Section

    private var textSection: some View {
        VStack(spacing: 8) {
            Text("Allow camera access to take photos and videos.")
                .font(.title3)
                .foregroundColor(.appPrimaryText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Permission Cards

    private var permissionCards: some View {
        VStack(spacing: 12) {
            // Camera (Required)
            CameraPermissionCard(
                icon: "camera.fill",
                tint: .gray,
                title: String(localized: "Camera"),
                description: String(localized: "Take photos and videos"),
                isOptional: false,
                status: cameraStatus.toCardStatus,
                onTap: { handleCameraTap() }
            )

            // Location (Optional)
            CameraPermissionCard(
                icon: "location.fill",
                tint: .blue,
                title: String(localized: "Location"),
                description: String(localized: "Add location to your photos"),
                isOptional: true,
                status: locationStatus.toCardStatus,
                onTap: { handleLocationTap() }
            )

            // Microphone (Optional)
            CameraPermissionCard(
                icon: "mic.fill",
                tint: .orange,
                title: String(localized: "Microphone"),
                description: String(localized: "Record video with sound"),
                isOptional: true,
                status: microphoneStatus.toCardStatus,
                onTap: { handleMicrophoneTap() }
            )
        }
    }

    // MARK: - Continue Button

    private var continueButton: some View {
        Button {
            onComplete()
        } label: {
            Text("Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    // MARK: - Permission Logic

    private func checkAllPermissions() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        locationStatus = locationManager.authorizationStatus
    }

    // MARK: - Camera

    private func handleCameraTap() {
        if cameraStatus == .notDetermined {
            requestCameraPermission()
        } else {
            openSettings()
        }
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
            }
        }
    }

    // MARK: - Microphone

    private func handleMicrophoneTap() {
        if microphoneStatus == .notDetermined {
            requestMicrophonePermission()
        } else {
            openSettings()
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        }
    }

    // MARK: - Location

    private func handleLocationTap() {
        if locationStatus == .notDetermined {
            locationManager.requestPermission()
        } else {
            openSettings()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Permission Card Status

private enum PermissionCardStatus {
    case notDetermined
    case authorized
    case denied
}

// MARK: - AVAuthorizationStatus Extension

private extension AVAuthorizationStatus {
    var toCardStatus: PermissionCardStatus {
        switch self {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

// MARK: - CLAuthorizationStatus Extension

private extension CLAuthorizationStatus {
    var toCardStatus: PermissionCardStatus {
        switch self {
        case .authorizedWhenInUse, .authorizedAlways: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

// MARK: - Permission Card Component

private struct CameraPermissionCard: View {
    let icon: String
    /// The icon tile's color, matching the one Settings gives this permission
    let tint: Color
    let title: String
    let description: String
    let isOptional: Bool
    let status: PermissionCardStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Icon tile, as in Settings
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Text content
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.appPrimaryText)

                        if isOptional {
                            Text("Optional")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.appSecondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.appSecondaryText.opacity(0.15))
                                )
                        }
                    }

                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.appSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Status indicator
                statusIndicator
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.appCardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CameraPermissionCardButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.appSuccess)
                .symbolEffect(.bounce, value: status)
        case .denied:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(.appError)
                .symbolEffect(.bounce, value: status)
        case .notDetermined:
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
    }
}

// MARK: - Card Button Style

private struct CameraPermissionCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Location Permission Manager

@Observable
private class CameraLocationPermissionManager: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
}
