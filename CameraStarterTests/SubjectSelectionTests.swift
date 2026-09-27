//
//  SubjectSelectionTests.swift
//  CameraStarterTests
//

import CoreGraphics
import Foundation
import Testing
@testable import CameraStarter

/// A subject centered at (x, y) in Vision's normalized coordinates.
private func subject(
    x: CGFloat,
    y: CGFloat,
    size: CGFloat = 0.1,
    confidence: Float = 0.9,
    id: UUID = UUID()
) -> SubjectDetectionResult {
    SubjectDetectionResult(
        boundingBox: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size),
        confidence: confidence,
        kind: .face,
        id: id
    )
}

@Suite("Choosing the subject to focus on")
struct FocusSelectionTests {
    @Test func nothingToChooseFrom() {
        #expect(SubjectSelection.bestSubjectForFocus(from: []) == nil)
    }

    @Test func centeredSubjectBeatsALargerOneOffCenter() {
        let centered = subject(x: 0.5, y: 0.5, size: 0.1)
        let large = subject(x: 0.15, y: 0.15, size: 0.3)
        #expect(SubjectSelection.bestSubjectForFocus(from: [large, centered]) == centered)
    }

    @Test func amongCenteredSubjectsTheMostConfidentWins() {
        let unsure = subject(x: 0.45, y: 0.5, confidence: 0.5)
        let sure = subject(x: 0.55, y: 0.5, confidence: 0.95)
        #expect(SubjectSelection.bestSubjectForFocus(from: [unsure, sure]) == sure)
    }

    @Test func withNoneCenteredTheLargestWins() {
        let small = subject(x: 0.1, y: 0.1, size: 0.1)
        let large = subject(x: 0.85, y: 0.85, size: 0.2)
        #expect(SubjectSelection.bestSubjectForFocus(from: [small, large]) == large)
    }
}

@Suite("Keeping a subject's ID from frame to frame")
struct StableIDTests {
    private let threshold: CGFloat = 0.15

    @Test func firstFrameGetsFreshIDs() {
        let new = [subject(x: 0.3, y: 0.3), subject(x: 0.7, y: 0.7)]
        let ids = SubjectSelection.stableIDs(for: new, previous: [], matchThreshold: threshold)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
    }

    @Test func noDetectionsGetNoIDs() {
        let previous = [subject(x: 0.5, y: 0.5)]
        #expect(SubjectSelection.stableIDs(for: [], previous: previous, matchThreshold: threshold).isEmpty)
    }

    @Test func aSubjectThatMovesALittleKeepsItsID() {
        let id = UUID()
        let previous = [subject(x: 0.5, y: 0.5, id: id)]
        let moved = [subject(x: 0.55, y: 0.52)]
        #expect(SubjectSelection.stableIDs(for: moved, previous: previous, matchThreshold: threshold) == [id])
    }

    @Test func aSubjectThatJumpsFarGetsANewID() {
        let id = UUID()
        let previous = [subject(x: 0.2, y: 0.2, id: id)]
        let jumped = [subject(x: 0.8, y: 0.8)]
        let ids = SubjectSelection.stableIDs(for: jumped, previous: previous, matchThreshold: threshold)
        #expect(ids.count == 1)
        #expect(ids.first != id)
    }

    @Test func subjectsSideBySideEachKeepTheirOwnID() {
        let left = UUID(), right = UUID()
        let previous = [subject(x: 0.40, y: 0.5, id: left), subject(x: 0.50, y: 0.5, id: right)]
        // Listed in the opposite order, each a little closer to the other
        let new = [subject(x: 0.48, y: 0.5), subject(x: 0.42, y: 0.5)]
        #expect(SubjectSelection.stableIDs(for: new, previous: previous, matchThreshold: threshold) == [right, left])
    }
}
