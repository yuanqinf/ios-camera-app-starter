//
//  CameraPermissionView.swift
//  CameraStarter
//
//  Camera permission request with card-based UI
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

    /// The same tile the permission rows below use, at hero size, in the
    /// colors of a permission not yet asked for. Viewfinder rather than
    /// camera.fill, which the first row already shows.
    private var illustrationSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.appSecondaryColor, .appPrimaryColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 160, height: 160)

            Image(systemName: "camera.viewfinder")
                .font(.system(size: 72, weight: .semibold))
                .foregroundColor(.white)
        }
        // Decorative: the text under it says what the screen is for.
        .accessibilityHidden(true)
    }

    // MARK: - Text Section

    private var textSection: some View {
        VStack(spacing: 8) {
            Text("camera.permission.body".localized)
                .font(.system(size: 18))
                .foregroundColor(.appPrimaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
    }

    // MARK: - Permission Cards

    private var permissionCards: some View {
        VStack(spacing: 12) {
            // Camera (Required)
            CameraPermissionCard(
                icon: "camera.fill",
                title: "camera.permission.camera.title".localized,
                description: "camera.permission.camera.description".localized,
                isOptional: false,
                status: cameraStatus.toCardStatus,
                onTap: { handleCameraTap() }
            )

            // Location (Optional)
            CameraPermissionCard(
                icon: "location.fill",
                title: "camera.permission.location.title".localized,
                description: "camera.permission.location.description".localized,
                isOptional: true,
                status: locationStatus.toCardStatus,
                onTap: { handleLocationTap() }
            )

            // Microphone (Optional)
            CameraPermissionCard(
                icon: "mic.fill",
                title: "camera.permission.microphone.title".localized,
                description: "camera.permission.microphone.description".localized,
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
            HStack(spacing: 8) {
                Text("permission.continue".localized)
                    .font(.system(size: 17, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appPrimaryColor)
            )
        }
        .buttonStyle(PressableButtonStyle())
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
    let title: String
    let description: String
    let isOptional: Bool
    let status: PermissionCardStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Icon with gradient background
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconGradient)
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }

                // Text content
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.appPrimaryText)

                        if isOptional {
                            Text("permission.optional".localized)
                                .font(.system(size: 11, weight: .medium))
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
                        .font(.system(size: 13))
                        .foregroundColor(.appSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Status indicator
                statusIndicator
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(CameraPermissionCardButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var iconGradient: LinearGradient {
        switch status {
        case .authorized:
            return LinearGradient(
                colors: [.appSuccess, .appSuccess.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .denied:
            return LinearGradient(
                colors: [.appError, .appError.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .notDetermined:
            return LinearGradient(
                colors: [.appSecondaryColor, .appPrimaryColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
                .foregroundColor(.appSecondaryText)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.appCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }

    private var borderColor: Color {
        switch status {
        case .authorized:
            return Color.appSuccess.opacity(0.3)
        case .denied:
            return Color.appError.opacity(0.3)
        case .notDetermined:
            return Color.appDivider
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
