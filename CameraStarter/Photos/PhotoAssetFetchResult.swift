//
//  PhotoAssetFetchResult.swift
//  CameraStarter
//
//  Wrapper around PHFetchResult providing RandomAccessCollection interface
//

import Photos

class PhotoAssetFetchResult: RandomAccessCollection {
    private(set) var fetchResult: PHFetchResult<PHAsset>

    private var cache = [Int : PhotoAsset]()

    var startIndex: Int { 0 }
    var endIndex: Int { fetchResult.count }

    init(_ fetchResult: PHFetchResult<PHAsset>) {
        self.fetchResult = fetchResult
    }

    subscript(position: Int) -> PhotoAsset {
        // Clamp to valid range to prevent crash when photos are deleted externally
        let safePosition = Swift.min(Swift.max(position, 0), Swift.max(fetchResult.count - 1, 0))

        if let asset = cache[safePosition] {
            return asset
        }
        let asset = PhotoAsset(phAsset: fetchResult.object(at: safePosition), index: safePosition)
        cache[safePosition] = asset
        return asset
    }

    var phAssets: [PHAsset] {
        var assets = [PHAsset]()
        fetchResult.enumerateObjects { (object, count, stop) in
            assets.append(object)
        }
        return assets
    }
}

extension PhotoAssetFetchResult: Sequence {
    func makeIterator() -> PhotoAssetFetchResultIterator {
        return PhotoAssetFetchResultIterator(collection: self)
    }
}

struct PhotoAssetFetchResultIterator: IteratorProtocol {
    private let collection: PhotoAssetFetchResult
    private var currentIndex: Int = 0

    init(collection: PhotoAssetFetchResult) {
        self.collection = collection
    }

    mutating func next() -> PhotoAsset? {
        guard currentIndex < collection.count else {
            return nil
        }

        let asset = collection[currentIndex]
        currentIndex += 1
        return asset
    }
}
