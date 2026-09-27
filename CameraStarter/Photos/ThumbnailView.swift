//
//  ThumbnailView.swift
//  CameraStarter
//
//  The newest capture, in the square at the corner of the bottom bar.
//

import SwiftUI

struct ThumbnailView: View {
    /// The capture to show. Nil for an empty album.
    var image: Image?

    /// Rings the thumbnail in green, to mark a photo that just landed in it.
    var isFlashing = false

    private let shape = RoundedRectangle(cornerRadius: 10)

    var body: some View {
        ZStack {
            Color.appSecondaryBackground

            if let image {
                image
                    .resizable()
                    .scaledToFill()
                    .allowedDynamicRange(.high)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundColor(.appSecondaryText)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(shape)
        .overlay {
            shape.stroke(
                isFlashing ? Color.green : Color.appPrimaryText.opacity(0.2),
                lineWidth: isFlashing ? 3 : 2
            )
        }
        .animation(.easeInOut(duration: 0.3), value: isFlashing)
    }
}

#Preview {
    VStack(spacing: 20) {
        ThumbnailView(image: nil)
        ThumbnailView(image: Image(systemName: "photo.fill"))
        ThumbnailView(image: Image(systemName: "photo.fill"), isFlashing: true)
    }
    .padding()
    .background(Color.black)
}
