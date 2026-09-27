//
//  SubjectTrackingOverlay.swift
//  CameraStarter
//
//  Visual overlay for subject tracking
//  Uses CADisplayLink for smooth 60fps rendering with velocity extrapolation
//

import SwiftUI
import UIKit

// MARK: - SwiftUI Entry Point

/// Thin SwiftUI wrapper — passes data directly to UIKit layer
struct SubjectTrackingOverlay: UIViewRepresentable {
    let lockService: SubjectLockService
    let containerSize: CGSize
    let maskHeight: CGFloat

    func makeUIView(context: Context) -> TrackingBoxView {
        TrackingBoxView()
    }

    func updateUIView(_ uiView: TrackingBoxView, context: Context) {
        uiView.updateFromService(
            lockService: lockService,
            containerSize: containerSize,
            maskHeight: maskHeight
        )
    }
}

// MARK: - UIKit Tracking Box

/// Pure UIKit view with CADisplayLink for smooth box rendering
/// Receives data via updateFromService() called by SwiftUI, renders at 60fps
final class TrackingBoxView: UIView {

    private let boxLayer = CAShapeLayer()

    // Current interpolation state
    private var targetRect: CGRect = .zero
    private var displayRect: CGRect = .zero
    private var velocityX: CGFloat = 0
    private var velocityY: CGFloat = 0
    private var lastDataTime: CFTimeInterval = 0
    private var isBoxVisible: Bool = false

    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // Native camera style: warm yellow, rounded corners
        boxLayer.fillColor = UIColor.clear.cgColor
        boxLayer.strokeColor = UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0).cgColor  // #FFD60A systemYellow
        boxLayer.lineWidth = 1.5
        boxLayer.opacity = 0
        layer.addSublayer(boxLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Called by SwiftUI's updateUIView — bridge data into UIKit
    func updateFromService(lockService: SubjectLockService, containerSize: CGSize, maskHeight: CGFloat) {
        let state = lockService.lockState
        let subject = lockService.trackedSubject

        let shouldShow: Bool
        switch state {
        case .detecting, .tracking, .stable:
            shouldShow = subject != nil
        case .idle, .lost:
            shouldShow = false
        }

        if shouldShow, let subject {
            let visibleHeight = containerSize.height - (maskHeight * 2)
            let box = subject.boundingBox

            let rect = CGRect(
                x: box.minX * containerSize.width,
                y: maskHeight + (1 - box.maxY) * visibleHeight,
                width: box.width * containerSize.width,
                height: box.height * visibleHeight
            )

            // Convert velocity: normalized units/frame → pixels/second
            let fps: CGFloat = 10.0  // ~100ms tracking interval
            let vx = subject.velocity.x * containerSize.width * fps
            let vy = -subject.velocity.y * visibleHeight * fps

            targetRect = rect
            velocityX = vx
            velocityY = vy
            lastDataTime = CACurrentMediaTime()

            if displayRect == .zero {
                displayRect = rect
            }

            if !isBoxVisible {
                isBoxVisible = true
                startDisplayLink()
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.15)
                boxLayer.opacity = 1
                CATransaction.commit()
            }

            // Stable → fade out after delay
            if state == .stable {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.isBoxVisible else { return }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.5)
                    self.boxLayer.opacity = 0
                    CATransaction.commit()
                }
            }
        } else if isBoxVisible {
            isBoxVisible = false
            stopDisplayLink()
            displayRect = .zero
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            boxLayer.opacity = 0
            boxLayer.path = nil
            CATransaction.commit()
        }
    }

    // MARK: - CADisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard isBoxVisible else { return }

        let dt = CACurrentMediaTime() - lastDataTime

        // Extrapolate using velocity for short durations, then just lerp to target
        let goalRect: CGRect
        if dt < 0.12 {
            goalRect = CGRect(
                x: targetRect.origin.x + velocityX * CGFloat(dt),
                y: targetRect.origin.y + velocityY * CGFloat(dt),
                width: targetRect.width,
                height: targetRect.height
            )
        } else {
            goalRect = targetRect
        }

        // Exponential lerp — converges quickly without overshoot
        let alpha: CGFloat = 0.3
        displayRect = CGRect(
            x: displayRect.origin.x + alpha * (goalRect.origin.x - displayRect.origin.x),
            y: displayRect.origin.y + alpha * (goalRect.origin.y - displayRect.origin.y),
            width: displayRect.width + alpha * (goalRect.width - displayRect.width),
            height: displayRect.height + alpha * (goalRect.height - displayRect.height)
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boxLayer.path = UIBezierPath(roundedRect: displayRect, cornerRadius: 10).cgPath
        CATransaction.commit()
    }

    override func removeFromSuperview() {
        stopDisplayLink()
        super.removeFromSuperview()
    }
}

// MARK: - Preview

#Preview("Tracking") {
    ZStack {
        Color.black.ignoresSafeArea()
    }
}
