//
//  FrameCornerOverlay.swift
//  CameraStarter
//
//  Frame corner decoration - Simulates iPhone Camera app style
//

import SwiftUI

/// Corner decoration mode
enum CornerDecorationMode: Equatable {
    case normal          // White corners (default)
    case shotGuide       // Yellow gradient corners
}

/// Frame corner decoration view (L-shaped lines)
struct FrameCornerOverlay: View {
    /// Aspect ratio (optional, used to adjust corner positions)
    var aspectRatio: AspectRatio = .ratio4_3

    /// Container width (used to calculate mask height)
    var containerWidth: CGFloat = 0

    /// Container height (4:3 preview height)
    var containerHeight: CGFloat = 0

    /// Corner decoration mode
    var mode: CornerDecorationMode = .normal

    /// Hide all corners (for video mode - no frame indicators)
    var isHidden: Bool = false

    /// Line length
    private let lineLength: CGFloat = 20

    /// Line width
    private let lineWidth: CGFloat = 2.5

    /// Calculate top and bottom mask height (used to position corners)
    private var maskH: CGFloat {
        guard containerWidth > 0, containerHeight > 0 else { return 0 }
        return aspectRatio.maskHeight(containerWidth: containerWidth, containerHeight: containerHeight)
    }

    var body: some View {
        ZStack {
            // Top left corner
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    CornerView(
                        corner: .topLeft,
                        lineLength: lineLength,
                        lineWidth: lineWidth,
                        mode: mode
                    )
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, maskH)

            // Top right corner
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer()
                    CornerView(
                        corner: .topRight,
                        lineLength: lineLength,
                        lineWidth: lineWidth,
                        mode: mode
                    )
                }
                Spacer()
            }
            .padding(.top, maskH)

            // Bottom left corner
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    CornerView(
                        corner: .bottomLeft,
                        lineLength: lineLength,
                        lineWidth: lineWidth,
                        mode: mode
                    )
                    Spacer()
                }
            }
            .padding(.bottom, maskH)

            // Bottom right corner
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    Spacer()
                    CornerView(
                        corner: .bottomRight,
                        lineLength: lineLength,
                        lineWidth: lineWidth,
                        mode: mode
                    )
                }
            }
            .padding(.bottom, maskH)
        }
        .opacity(isHidden ? 0 : 1)
        .animation(.easeInOut(duration: 0.8), value: aspectRatio)
        .animation(.easeInOut(duration: 0.8), value: mode)
        .animation(.easeInOut(duration: 0.8), value: isHidden)
    }
}

// MARK: - Corner Position

private enum CornerPosition {
    case topLeft, topRight, bottomLeft, bottomRight
}

// MARK: - Corner View

private struct CornerView: View {
    let corner: CornerPosition
    let lineLength: CGFloat
    let lineWidth: CGFloat
    let mode: CornerDecorationMode

    /// Yellow gradient for active modes (native camera style)
    private let yellowGradient = LinearGradient(
        colors: [.yellow],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Get the appropriate gradient based on mode
    private var activeGradient: LinearGradient {
        switch mode {
        case .normal:
            return LinearGradient(colors: [.white], startPoint: .top, endPoint: .bottom)
        case .shotGuide:
            return yellowGradient
        }
    }

    var body: some View {
        // Main corner stroke
        cornerShape
            .stroke(
                activeGradient,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .opacity(mode == .normal ? 0.9 : 1.0)
            .frame(width: lineLength, height: lineLength)
    }

    /// Corner shape path
    private var cornerShape: Path {
        Path { path in
            switch corner {
            case .topLeft:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: lineLength))
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: lineLength, y: 0))

            case .topRight:
                path.move(to: CGPoint(x: lineLength, y: 0))
                path.addLine(to: CGPoint(x: lineLength, y: lineLength))
                path.move(to: CGPoint(x: lineLength, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 0))

            case .bottomLeft:
                path.move(to: CGPoint(x: 0, y: lineLength))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.move(to: CGPoint(x: 0, y: lineLength))
                path.addLine(to: CGPoint(x: lineLength, y: lineLength))

            case .bottomRight:
                path.move(to: CGPoint(x: lineLength, y: lineLength))
                path.addLine(to: CGPoint(x: lineLength, y: 0))
                path.move(to: CGPoint(x: lineLength, y: lineLength))
                path.addLine(to: CGPoint(x: 0, y: lineLength))
            }
        }
    }

}

// MARK: - Preview

#Preview("Normal Mode") {
    ZStack {
        Color.black.ignoresSafeArea()

        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 300, height: 400)
            .overlay {
                FrameCornerOverlay(mode: .normal)
                    .padding(16)
            }
    }
}

#Preview("Shot Guide Mode") {
    ZStack {
        Color.black.ignoresSafeArea()

        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 300, height: 400)
            .overlay {
                FrameCornerOverlay(mode: .shotGuide)
                    .padding(16)
            }
    }
}

