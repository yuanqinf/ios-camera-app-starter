//
//  AspectRatioManager.swift
//  CameraStarter
//
//  Aspect ratio manager
//  Supports 4:3, 16:9, 1:1 ratios
//

import SwiftUI

/// Aspect ratio
enum AspectRatio: String, CaseIterable {
    case ratio4_3 = "4:3"
    case ratio16_9 = "16:9"
    case ratio1_1 = "1:1"

    /// Aspect ratio value (width/height)
    var value: CGFloat {
        switch self {
        case .ratio4_3:
            return 3.0 / 4.0  // Width/height in portrait mode
        case .ratio16_9:
            return 9.0 / 16.0
        case .ratio1_1:
            return 1.0
        }
    }

    /// Display text
    var displayText: String {
        rawValue
    }

    /// Next ratio (cycle through)
    var next: AspectRatio {
        switch self {
        case .ratio4_3:
            return .ratio16_9
        case .ratio16_9:
            return .ratio1_1
        case .ratio1_1:
            return .ratio4_3
        }
    }

    /// Calculate preview height based on container width
    func previewHeight(for width: CGFloat) -> CGFloat {
        switch self {
        case .ratio4_3:
            return width * 4.0 / 3.0
        case .ratio16_9:
            return width * 16.0 / 9.0
        case .ratio1_1:
            return width
        }
    }

    /// Calculate top/bottom mask height (for displaying target ratio area)
    ///
    /// Preview layer behavior:
    /// - 16:9 mode: use `resizeAspectFill` to fill 16:9 container, no mask needed
    /// - 4:3 mode: use `resizeAspect` to show full 4:3 content (built-in letterboxing)
    /// - 1:1 mode: use `resizeAspect` to show full 4:3, needs mask to crop to 1:1
    ///
    /// - Parameters:
    ///   - containerWidth: Container width (screen width)
    ///   - containerHeight: Container height (16:9 preview height = width * 16/9)
    /// - Returns: Top/bottom mask height (symmetric)
    func maskHeight(containerWidth: CGFloat, containerHeight: CGFloat) -> CGFloat {
        switch self {
        case .ratio4_3:
            // 4:3: use resizeAspect, letterboxing already shows correct area
            // Still return mask height because letterboxing is transparent, needs black mask overlay
            let targetHeight = containerWidth * 4.0 / 3.0
            return max(0, (containerHeight - targetHeight) / 2.0)
        case .ratio16_9:
            // 16:9: use resizeAspectFill to fill container, no mask needed
            return 0
        case .ratio1_1:
            // 1:1: use resizeAspect to show full 4:3 content
            // Need mask from container top to 1:1 target area
            // 1:1 target area = square, side length = containerWidth, centered in container
            let targetHeight = containerWidth
            return max(0, (containerHeight - targetHeight) / 2.0)
        }
    }


}

/// Aspect ratio mask view (top/bottom black masks, for cropping from 16:9 container to target ratio)
struct AspectRatioMaskView: View {
    let aspectRatio: AspectRatio
    let containerWidth: CGFloat
    let containerHeight: CGFloat

    var body: some View {
        let maskH = aspectRatio.maskHeight(
            containerWidth: containerWidth,
            containerHeight: containerHeight
        )

        // Top/bottom black masks (used for 4:3 and 1:1 modes, no mask for 16:9)
        if maskH > 0 {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: maskH)
                Spacer()
                Rectangle()
                    .fill(Color.black)
                    .frame(height: maskH)
            }
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.3), value: aspectRatio)
        }
    }
}

// MARK: - Preview

// 16:9 container height = 390 * 16/9 ≈ 693
private let previewContainerHeight: CGFloat = 390 * 16.0 / 9.0

#Preview("4:3") {
    ZStack {
        Color.gray
        AspectRatioMaskView(
            aspectRatio: .ratio4_3,
            containerWidth: 390,
            containerHeight: previewContainerHeight
        )
    }
    .frame(width: 390, height: previewContainerHeight)
}

#Preview("16:9") {
    ZStack {
        Color.gray
        AspectRatioMaskView(
            aspectRatio: .ratio16_9,
            containerWidth: 390,
            containerHeight: previewContainerHeight
        )
    }
    .frame(width: 390, height: previewContainerHeight)
}

#Preview("1:1") {
    ZStack {
        Color.gray
        AspectRatioMaskView(
            aspectRatio: .ratio1_1,
            containerWidth: 390,
            containerHeight: previewContainerHeight
        )
    }
    .frame(width: 390, height: previewContainerHeight)
}
