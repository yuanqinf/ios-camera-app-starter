//
//  PreviewView.swift
//  CameraStarter
//
//  Camera preview view - UIKit bridge to SwiftUI
//

import SwiftUI
import AVFoundation

/// Camera preview view
///
/// Uses UIViewRepresentable to bridge AVCaptureVideoPreviewLayer to SwiftUI
/// Provides zero-configuration, high-performance camera preview rendering
///
/// ## Preview and Photo Consistency
///
/// iPhone camera sensor outputs 4:3 ratio (in portrait: 3:4, meaning height = 1.33x width).
/// The UI uses a 16:9 container (in portrait: 9:16, meaning height = 1.78x width).
///
/// ### Native Camera 16:9 Behavior:
/// - 16:9 photo crops LEFT and RIGHT sides of the 4:3 sensor output
/// - Example: 4:3 = 3024×4032, 16:9 = 2268×4032 (height unchanged, width reduced)
/// - This creates a "zoomed in" feeling because you lose peripheral vision
///
/// ### Implementation:
/// - **16:9 mode**: Use `resizeAspectFill` - fills 16:9 container, crops sides of 4:3 content
/// - **4:3 mode**: Use `resizeAspect` - shows full 4:3 content, letterboxed in container
/// - **1:1 mode**: Use `resizeAspect` - shows full 4:3, use mask to show square center
struct PreviewView: UIViewRepresentable {

    /// Preview layer (provided by CameraManager)
    let previewLayer: AVCaptureVideoPreviewLayer

    /// Currently selected aspect ratio
    var aspectRatio: AspectRatio = .ratio4_3

    func makeUIView(context: Context) -> UIView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer = previewLayer
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let containerView = uiView as? PreviewContainerView else { return }
        containerView.aspectRatio = aspectRatio
        containerView.setNeedsLayout()
    }
}

/// Preview container view - handles preview layer layout
private class PreviewContainerView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?
    var aspectRatio: AspectRatio = .ratio4_3

    override func layoutSubviews() {
        super.layoutSubviews()

        guard let previewLayer = previewLayer else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }

        // Set preview layer frame
        previewLayer.frame = bounds

        // Select appropriate videoGravity based on ratio
        switch aspectRatio {
        case .ratio16_9:
            // 16:9 mode: container is 16:9, photo also cropped to 16:9
            // Use aspectFill to fill container - this crops the sides of 4:3 content
            // This matches native iOS camera behavior where 16:9 = crop left/right
            previewLayer.videoGravity = .resizeAspectFill
        case .ratio4_3, .ratio1_1:
            // 4:3 and 1:1 modes: show complete 4:3 sensor output
            // Use aspectFit (letterboxed), then mask to show target area
            previewLayer.videoGravity = .resizeAspect
        }

        // Reset any transforms
        previewLayer.setAffineTransform(.identity)
    }
}
