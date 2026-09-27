//
//  ZoomControl.swift
//  CameraStarter
//
//  Zoom control component - iPhone native camera style
//  Small circular buttons + shows current zoom value when between presets
//

import SwiftUI

struct ZoomControl: View {
    // Current actual zoom factor (can be any value, not just presets)
    @Binding var currentZoom: CGFloat

    // Available preset zoom factors
    let presetZooms: [CGFloat]

    // Zoom change callback (receives target preset zoom)
    let onZoomChange: (CGFloat) -> Void

    // Rotation angle for landscape mode (text rotation only)
    var rotationAngle: Angle = .zero

    // Debounce: pending zoom task
    @State private var pendingZoomTask: Task<Void, Never>? = nil

    init(
        selectedZoom: Binding<CGFloat>,
        availableZooms: [CGFloat] = [0.5, 1.0, 2.0, 3.0],
        rotationAngle: Angle = .zero,
        onZoomChange: @escaping (CGFloat) -> Void
    ) {
        self._currentZoom = selectedZoom
        self.presetZooms = availableZooms
        self.rotationAngle = rotationAngle
        self.onZoomChange = onZoomChange
    }

    /// Find which preset button should be "active" based on current zoom
    /// - Returns: The preset that owns this zoom range
    private func activePreset(for zoom: CGFloat) -> CGFloat {
        // <1 → 0.5x button
        // >=1 and <2 → 1x button
        // >=2 and <3 → 2x button
        // >=3 → 3x button
        if zoom < 1.0 {
            return 0.5
        } else if zoom < 2.0 {
            return 1.0
        } else if zoom < 3.0 {
            return 2.0
        } else {
            return 3.0
        }
    }

    /// Check if current zoom exactly matches a preset
    private var isExactPreset: Bool {
        presetZooms.contains { abs($0 - currentZoom) < 0.01 }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(presetZooms, id: \.self) { preset in
                let isActive = activePreset(for: currentZoom) == preset
                let showCurrentValue = isActive && !isExactPreset

                ZoomButton(
                    preset: preset,
                    displayZoom: showCurrentValue ? currentZoom : preset,
                    isActive: isActive,
                    rotationAngle: rotationAngle
                ) {
                    handleZoomTap(preset)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            // Dark translucent background with subtle shadow for visibility on light backgrounds
            Capsule()
                .fill(Color.black.opacity(0.3))
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
    }

    private func handleZoomTap(_ preset: CGFloat) {
        // Haptic feedback
        Haptics.light()

        // Update to preset value with spring animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            currentZoom = preset
        }

        // Debounce logic: cancel previous task, delay new task execution
        // If user taps rapidly in succession, only execute the last one
        pendingZoomTask?.cancel()

        pendingZoomTask = Task {
            // Wait 150ms, if there's a new tap during this period, this task will be cancelled
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms

            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            // Execute zoom to preset value
            await MainActor.run {
                onZoomChange(preset)
            }
        }
    }
}

/// Single zoom button (small circular button style)
private struct ZoomButton: View {
    let preset: CGFloat      // The preset value this button represents
    let displayZoom: CGFloat // The value to display (could be current zoom or preset)
    let isActive: Bool       // Whether this button is currently active
    let rotationAngle: Angle
    let action: () -> Void

    // Circle size for button (visual size)
    private let buttonSize: CGFloat = 32

    var body: some View {
        Button(action: action) {
            // When active, show text with "×", when not active, show only number
            Text(displayText)
                .font(.system(size: isActive ? 12 : 11, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .appCameraActive : .white.opacity(0.6))
                .rotationEffect(rotationAngle)
                .animation(.easeInOut(duration: 0.3), value: rotationAngle)
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    // Circular background
                    Circle()
                        .fill(isActive ? Color.black.opacity(0.35) : Color.black.opacity(0.2))
                )
                .overlay(
                    // Unselected has thin border, more visible
                    Circle()
                        .strokeBorder(
                            isActive ? Color.clear : Color.white.opacity(0.15),
                            lineWidth: 0.5
                        )
                )
                .scaleEffect(isActive ? 1.15 : 0.95)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(isActive ? "a11y.zoom.selected".localized : "a11y.zoom.tap.hint".localized)
    }

    // Display text (add "×" when active)
    private var displayText: String {
        let baseText: String
        if displayZoom == 0.5 || (displayZoom < 1.0 && abs(displayZoom - 0.5) < 0.01) {
            baseText = ".5"
        } else if displayZoom < 1.0 {
            // Show one decimal for values like 0.7, 0.8
            baseText = String(format: "%.1f", displayZoom)
        } else if displayZoom.truncatingRemainder(dividingBy: 1.0) < 0.01 ||
                  displayZoom.truncatingRemainder(dividingBy: 1.0) > 0.99 {
            // Whole number (e.g., 1, 2, 3)
            baseText = String(format: "%.0f", displayZoom)
        } else {
            // Decimal (e.g., 1.3, 2.7)
            baseText = String(format: "%.1f", displayZoom)
        }

        // Add "×" only when active
        return isActive ? "\(baseText)×" : baseText
    }

    // Accessibility text (always shows the preset value)
    private var accessibilityText: String {
        let zoomValue: String
        if preset == 0.5 {
            zoomValue = "0.5"
        } else if preset.truncatingRemainder(dividingBy: 1.0) == 0 {
            zoomValue = String(format: "%.0f", preset)
        } else {
            zoomValue = String(format: "%.1f", preset)
        }
        return String(format: "a11y.zoom.level".localized, zoomValue)
    }
}

#Preview {
    ZStack {
        Color.appBlack.ignoresSafeArea()

        VStack(spacing: 30) {
            // Exact preset
            ZoomControl(
                selectedZoom: .constant(1.0),
                onZoomChange: { _ in }
            )

            // Between presets (1.3x shows on 1x button)
            ZoomControl(
                selectedZoom: .constant(1.3),
                onZoomChange: { _ in }
            )

            // Between presets (2.7x shows on 2x button)
            ZoomControl(
                selectedZoom: .constant(2.7),
                onZoomChange: { _ in }
            )

            // Max zoom (5x shows on 3x button)
            ZoomControl(
                selectedZoom: .constant(5.0),
                onZoomChange: { _ in }
            )

            Spacer()
        }
        .padding(.top, 100)
    }
}
