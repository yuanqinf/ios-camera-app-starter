//
//  CoordinateConverterTests.swift
//  CameraStarterTests
//

import CoreGraphics
import Testing
@testable import CameraStarter

/// Vision puts the origin at the bottom left; AVFoundation's device space and
/// UIKit put it at the top left.
@Suite("Converting between coordinate spaces")
struct CoordinateConverterTests {
    @Test func visionPointFlipsVerticallyIntoDeviceSpace() {
        let point = CoordinateConverter.visionToDevice(point: CGPoint(x: 0.25, y: 0.8))
        #expect(point.x == 0.25)
        #expect(abs(point.y - 0.2) < 1e-9)
    }

    @Test func visionRectKeepsItsSizeAndMeasuresFromTheTop() {
        let rect = CoordinateConverter.visionToDevice(rect: CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3))
        #expect(rect.origin.x == 0.1)
        #expect(abs(rect.origin.y - 0.1) < 1e-9)  // 1 - (0.6 + 0.3)
        #expect(rect.size == CGSize(width: 0.2, height: 0.3))
    }

    @Test func visionPointScalesToTheView() {
        let point = CoordinateConverter.visionToUI(point: CGPoint(x: 0.5, y: 0.25), viewSize: CGSize(width: 400, height: 800))
        #expect(point == CGPoint(x: 200, y: 600))
    }

    @Test func visionRectScalesToTheView() {
        let rect = CoordinateConverter.visionToUI(
            rect: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
            viewSize: CGSize(width: 400, height: 800)
        )
        #expect(rect == CGRect(x: 100, y: 200, width: 200, height: 200))
    }

    @Test func theCenterStaysPut() {
        let center = CGPoint(x: 0.5, y: 0.5)
        #expect(CoordinateConverter.visionToDevice(point: center) == center)
    }
}
