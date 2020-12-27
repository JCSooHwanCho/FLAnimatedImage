//
//  FLAnimatedImage+Swift.swift
//  FLAnimatedImage
//
//  Created by Joshua on 2020/12/27.
//  Copyright © 2020 com.flipboard. All rights reserved.
//

import UIKit
import ImageIO
import MobileCoreServices

let kFLAnimatedImageDelayTimeIntervalMinimum: Double = 0.02

fileprivate enum FLAnimatedImageDataSizeCategory: UInt {
    case all = 10
    case `default` = 75
    case onDemand = 250
    case Unsupported
}

fileprivate enum FLAnimatedImageFrameCacheSize: UInt {
    case noLimit = 0
    case LowMemory = 1
    case GrowAfterMemoryWarning = 2
    case Default = 5
}

final class FLAnimatedImage: NSObject {
    let posterImage: UIImage?
    var size: CGSize {
        return posterImage?.size ?? .zero
    }

    private let data: Data

    private(set) var loopCount: Int
    private(set) var delayTimesForIndices: [Int:Double]
    private(set) var frameCount: Int

    private let frameCacheSizeOptimal: Int
    private let isPredrawingEnabled: Bool
    private var frameCacheSizeMaxInternal: Int = .max {
        didSet {
            guard oldValue != self.frameCacheSizeMaxInternal else { return }

            if self.frameCacheSizeMaxInternal < self.frameCacheSizeCurrent {
                self.purgeFrameCacheIfNeeded()
            }
        }
    }

    private var requestedFrameIndex: Int = -1
    private var posterImageFrameIndex: Int = -1
    private var cachedFramesForIndexes: [Int: UIImage]
    private var cachedFrameIndexes: IndexSet {
        return IndexSet(cachedFramesForIndexes.keys)
    }

    private var requestedFrameIndexes: IndexSet
    private var allFramesIndexSet: IndexSet {
        return IndexSet(0..<self.frameCount)
    }

    private var memoryWarningCount: UInt = 0
    private lazy var serialQueue: DispatchQueue = {
        return DispatchQueue(label: "com.flipboard.framecachingqueue")

    }()

    private let imageSource: CGImageSource

    var frameCacheSizeCurrent: Int {
        var result = self.frameCacheSizeOptimal

        if self.frameCacheSizeMax > FLAnimatedImageFrameCacheSize.noLimit.rawValue {
            result = min(result, self.frameCacheSizeMax)
        }

        if self.frameCacheSizeMaxInternal > FLAnimatedImageFrameCacheSize.noLimit.rawValue {
            result = min(result, self.frameCacheSizeMaxInternal)
        }

        return result
    }

    var frameCacheSizeMax: Int = .max {
        didSet {
            guard oldValue != self.frameCacheSizeMax else { return }

            if self.frameCacheSizeMax < self.frameCacheSizeCurrent {
                self.purgeFrameCacheIfNeeded()
            }
        }
    }


    func imageLazyliCached(at index: UInt) -> UIImage? {
        return nil
    }

    static func size(for image: UIImage) -> CGSize {
        return image.size
    }

    static func size(for image: FLAnimatedImage) -> CGSize {
        return image.size
    }


    init?(withAnimatedGIFData data: Data, optimalFrameCacheSize: Int = 0, predrawingEnabled: Bool = true) {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache as CFString : false as NSNumber] as CFDictionary) else {
            return nil
        }

        guard let imageSourceContainerType = CGImageSourceGetType(imageSource),
            UTTypeConformsTo(imageSourceContainerType, kUTTypeGIF) else {
                return nil
        }

        let imageCount = CGImageSourceGetCount(imageSource)

        if imageCount == 0 {
            return nil
        }

        self.data = data
        self.isPredrawingEnabled = predrawingEnabled
        self.imageSource = imageSource

        let imageProperties: NSDictionary? = CGImageSourceCopyProperties(imageSource, nil)

        let gifDict = imageProperties?.object(forKey: kCGImagePropertyGIFDictionary) as? NSDictionary

        self.loopCount = (gifDict?.object(forKey: kCGImagePropertyGIFLoopCount) as? NSNumber)?.intValue ?? 0

        var skippedFrameCount = 0

        var delayTimesForIndices = [Int:Double]()
        delayTimesForIndices.reserveCapacity(imageCount)

        var cachedFramesForIndexes = [Int:UIImage]()
        self.requestedFrameIndexes = IndexSet()

        var posterImage: UIImage? = nil
        var posterImageIndex: Int = -1

        for i in 0..<imageCount {
            guard let cgFrameImage = CGImageSourceCreateImageAtIndex(imageSource, i, nil) else {
                skippedFrameCount += 1
                continue
            }

            let frameImage = UIImage(cgImage: cgFrameImage)

            if posterImage == nil {
                posterImage = frameImage
                posterImageIndex = imageCount

                cachedFramesForIndexes[i] = frameImage
            }


            let frameProperties: NSDictionary? = CGImageSourceCopyPropertiesAtIndex(imageSource, i, nil)
            let framePropertiesGIF: NSDictionary? = frameProperties?.object(forKey: kCGImagePropertyGIFDictionary) as? NSDictionary

            var delayTime: Double? = (framePropertiesGIF?.object(forKey: kCGImagePropertyGIFUnclampedDelayTime) as? NSNumber)?.doubleValue

            if delayTime == nil {
                delayTime = (framePropertiesGIF?.object(forKey: kCGImagePropertyGIFDelayTime) as? NSNumber)?.doubleValue
            }

            if delayTime == nil {
                if i == 0 {
                    delayTime = 0.1
                } else {
                    delayTime = delayTimesForIndices[i-1]
                }
            }

            var unwrappedDelayTime = delayTime ?? 0.0

            if unwrappedDelayTime < kFLAnimatedImageDelayTimeIntervalMinimum - .ulpOfOne {
                unwrappedDelayTime = 0.1
            }

            delayTimesForIndices[i] = unwrappedDelayTime
        }

        self.posterImage = posterImage
        self.posterImageFrameIndex = posterImageIndex

        self.delayTimesForIndices = delayTimesForIndices
        self.frameCount = imageCount

        self.cachedFramesForIndexes = cachedFramesForIndexes

        self.frameCacheSizeOptimal = optimalFrameCacheSize

        super.init()
    }

    func imageLazilyCached(at index: Int) -> UIImage? {
        if index >= self.frameCount {
            return nil
        }

        self.requestedFrameIndex = index

        if self.cachedFrameIndexes.count < self.frameCount {

            let willBeRemovedIndices = self.cachedFrameIndexes.union(self.requestedFrameIndexes)

            var frameIndexesToAddToCache = self.frameIndexesToCache().filteredIndexSet {
                !willBeRemovedIndices.contains($0)
            }
            frameIndexesToAddToCache.remove(self.posterImageFrameIndex)

            if frameIndexesToAddToCache.count > 0 {
                self.addFrameIndicesToCache(frameIndexesToAddToCache: frameIndexesToAddToCache)
            }
        }

        let image = self.cachedFramesForIndexes[index]

        self.purgeFrameCacheIfNeeded()

        return image
    }

    private func addFrameIndicesToCache(frameIndexesToAddToCache indexSet: IndexSet) {
        let firstRange = self.requestedFrameIndex..<frameCount

        let secondRange = 0..<requestedFrameIndex

        self.requestedFrameIndexes.formUnion(indexSet)

        self.serialQueue.async { [weak self] in

            let retrievingImageAction: (Int) -> Void = { [weak self] i in
                guard let image = self?.image(at: i) else { return }

                DispatchQueue.main.async {
                    self?.cachedFramesForIndexes[i] = image

                    self?.requestedFrameIndexes.remove(i)
                }
            }

            for i in firstRange {
                retrievingImageAction(i)
            }

            for i in secondRange {
                retrievingImageAction(i)
            }
        }
    }

    // MARK :- Frame Loading
    func image(at index: Int) -> UIImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(self.imageSource, index, nil) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)

        if self.isPredrawingEnabled {
            return Self.predrawnImage(from: uiImage)
        }

        return uiImage
    }

    // MARK :- Frame Caching

    private func frameIndexesToCache() -> IndexSet {
        if self.frameCacheSizeCurrent == self.frameCount {
            return self.allFramesIndexSet
        } else {
            var indexesToCache = IndexSet()

            let firstLength = min(self.frameCacheSizeCurrent, self.frameCount - self.requestedFrameIndex)

            indexesToCache.insert(integersIn: self.requestedFrameIndex..<(self.requestedFrameIndex+firstLength))

            let secondLength = self.frameCacheSizeCurrent - firstLength

            if secondLength > 0 {
                indexesToCache.insert(integersIn: 0..<secondLength)
            }

            indexesToCache.insert(self.posterImageFrameIndex)

            return indexesToCache
        }
    }

    private func purgeFrameCacheIfNeeded() {
        if self.cachedFrameIndexes.count > self.frameCacheSizeCurrent {
            let frameIndexesToCache = self.frameIndexesToCache()

            let indexesToPurge = self.cachedFrameIndexes.filteredIndexSet {
                !frameIndexesToCache.contains($0)
            }

            indexesToPurge.forEach { index in
                self.cachedFramesForIndexes.removeValue(forKey: index)
            }
        }
    }

    // MARK :- Image Decoding
    static func predrawnImage(from image: UIImage) -> UIImage { let colorSpaceDeviceRGB =  CGColorSpaceCreateDeviceRGB()

        let numberOfComponents = colorSpaceDeviceRGB.numberOfComponents + 1

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let bitsPerComponent = Int(CHAR_BIT)

        let bitsPerPixel = bitsPerComponent * numberOfComponents
        let bytesPerPixel = bitsPerPixel / Int(BYTE_SIZE)
        let bytesPerRow = bytesPerPixel * width

        guard let cgImage = image.cgImage else {
            return image
        }

        var alphaInfo = cgImage.alphaInfo

        if alphaInfo == .none || alphaInfo == .alphaOnly {
            alphaInfo = .noneSkipFirst
        } else if alphaInfo == .first {
            alphaInfo = .premultipliedFirst
        } else if alphaInfo == .last {
            alphaInfo = .premultipliedLast
        }

        guard let bitmapContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpaceDeviceRGB, bitmapInfo: alphaInfo.rawValue) else {
            return image
        }

        bitmapContext.draw(cgImage, in: CGRect(origin: .zero, size: image.size))

        guard let predrawnImage = bitmapContext.makeImage() else {
            return image
        }

        return UIImage(cgImage: predrawnImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
