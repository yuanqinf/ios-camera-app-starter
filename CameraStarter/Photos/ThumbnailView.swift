//
//  ThumbnailView.swift
//  CameraStarter
//
//  Created by Yuanqin Fan on 11/10/25.
//

import SwiftUI

/// Thumbnail feedback type
enum ThumbnailFeedbackType: Equatable {
    case saved     // Green border flash for saved photo
    case discarded // Red border shake for discarded photo
}

struct ThumbnailView: View {
    var image: Image?
    var pendingCount: Int = 0  // Number of pending photos to save
    var feedbackType: ThumbnailFeedbackType?

    private var isProcessing: Bool {
        pendingCount > 0
    }

    /// Border color based on feedback type
    private var borderColor: Color {
        switch feedbackType {
        case .saved:
            return .green
        case .discarded:
            return .red
        case .none:
            return .appPrimaryText.opacity(0.2)
        }
    }

    /// Border width based on feedback type
    private var borderWidth: CGFloat {
        feedbackType != nil ? 3 : 2
    }

    var body: some View {
        ZStack {
            // Base layer: thumbnail
            thumbnailBase

            // Processing overlay
            if isProcessing {
                processingOverlay
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .modifier(ShakeEffect(shakes: feedbackType == .discarded ? 4 : 0))
        .animation(.easeInOut(duration: 0.2), value: pendingCount)
        .animation(.easeInOut(duration: 0.3), value: feedbackType)
    }

    private var thumbnailBase: some View {
        ZStack {
            if let image = image {
                // Has image - show it
                Color.appSecondaryBackground
                image
                    .resizable()
                    .scaledToFill()
                    .allowedDynamicRange(.high)  // Enable HDR display
                    .blur(radius: isProcessing ? 2 : 0)
            } else {
                // No image - show placeholder
                Color.appSecondaryBackground
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.appPrimaryColor.opacity(0.6))
            }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            // Semi-transparent background
            Color.appPrimaryText.opacity(0.5)

            VStack(spacing: 2) {
                // Count badge
                Text("\(pendingCount)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.appBackground)

                // Small progress indicator
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .appBackground))
                    .scaleEffect(0.5)
            }
        }
    }
}

// MARK: - Shake Effect

struct ShakeEffect: GeometryEffect {
    var shakes: Int
    var animatableData: CGFloat {
        get { CGFloat(shakes) }
        set { shakes = Int(newValue) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = sin(animatableData * .pi * 2) * 4
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

struct ThumbnailView_Previews: PreviewProvider {
    static let previewImage = Image(systemName: "photo.fill")
    static var previews: some View {
        VStack(spacing: 20) {
            // Placeholder (no image)
            ThumbnailView(image: nil, pendingCount: 0)
            // With image
            ThumbnailView(image: previewImage, pendingCount: 0)
            // Processing states
            ThumbnailView(image: previewImage, pendingCount: 3)
            ThumbnailView(image: previewImage, pendingCount: 10)
            // Feedback states
            ThumbnailView(image: previewImage, feedbackType: .saved)
            ThumbnailView(image: previewImage, feedbackType: .discarded)
        }
        .padding()
        .background(Color.black)
    }
}
