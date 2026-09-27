//
//  AspectRatioTests.swift
//  CameraStarterTests
//

import CoreGraphics
import Testing
@testable import CameraStarter

@Suite("Aspect ratios")
struct AspectRatioTests {
    /// An iPhone-width screen, and the 16:9 preview container on it.
    private let width: CGFloat = 390
    private var container: CGFloat { width * 16 / 9 }

    @Test(arguments: [
        (AspectRatio.ratio4_3, CGFloat(520)),
        (AspectRatio.ratio16_9, CGFloat(390 * 16.0 / 9.0)),
        (AspectRatio.ratio1_1, CGFloat(390)),
    ])
    func previewIsTallerThanWideInPortrait(ratio: AspectRatio, expectedHeight: CGFloat) {
        #expect(abs(ratio.previewHeight(for: width) - expectedHeight) < 1e-9)
    }

    @Test func sixteenByNineFillsTheContainerWithoutAMask() {
        #expect(AspectRatio.ratio16_9.maskHeight(containerWidth: width, containerHeight: container) == 0)
    }

    @Test func fourByThreeAndSquareMaskEvenlyTopAndBottom() {
        let fourThree = AspectRatio.ratio4_3.maskHeight(containerWidth: width, containerHeight: container)
        let square = AspectRatio.ratio1_1.maskHeight(containerWidth: width, containerHeight: container)
        #expect(abs(fourThree - (container - 520) / 2) < 1e-9)
        #expect(abs(square - (container - width) / 2) < 1e-9)
        #expect(square > fourThree)
    }

    @Test func maskNeverGoesNegative() {
        // A container shorter than the target, as on a very wide window
        #expect(AspectRatio.ratio4_3.maskHeight(containerWidth: width, containerHeight: 100) == 0)
    }

    @Test func tappingCyclesThroughAllThreeAndBack() {
        #expect(AspectRatio.ratio4_3.next == .ratio16_9)
        #expect(AspectRatio.ratio16_9.next == .ratio1_1)
        #expect(AspectRatio.ratio1_1.next == .ratio4_3)
    }
}
