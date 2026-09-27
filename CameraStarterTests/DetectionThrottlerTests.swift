//
//  DetectionThrottlerTests.swift
//  CameraStarterTests
//

import Foundation
import Testing
@testable import CameraStarter

@Suite("Throttling subject detection")
struct DetectionThrottlerTests {
    @Test func processesTheFirstFrameAndSkipsOneStraightAfter() async {
        let throttler = DetectionThrottler()
        #expect(await throttler.shouldProcess())
        #expect(await throttler.shouldProcess() == false)
    }

    @Test func runsAtTheFastIntervalWhileASubjectIsInView() async {
        let throttler = DetectionThrottler()
        await throttler.updateInterval(hasSubject: true, fastInterval: 0, normalInterval: 60, slowInterval: 60)
        #expect(await throttler.shouldProcess())
        #expect(await throttler.shouldProcess())
    }

    @Test func slowsDownOnlyAfterSeveralFramesWithoutASubject() async {
        let throttler = DetectionThrottler()
        await throttler.updateInterval(hasSubject: true, fastInterval: 0, normalInterval: 0, slowInterval: 60)

        // Up to five misses in a row: the normal interval, here zero
        for _ in 0..<5 {
            await throttler.updateInterval(hasSubject: false, fastInterval: 0, normalInterval: 0, slowInterval: 60)
        }
        #expect(await throttler.shouldProcess())
        #expect(await throttler.shouldProcess())

        // The sixth: the slow interval, so the next frame is skipped
        await throttler.updateInterval(hasSubject: false, fastInterval: 0, normalInterval: 0, slowInterval: 60)
        #expect(await throttler.shouldProcess() == false)
    }
}
