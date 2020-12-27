//
//  FLAnimatedImageView+Swift.swift
//  FLAnimatedImage
//
//  Created by Joshua on 2020/12/27.
//  Copyright © 2020 com.flipboard. All rights reserved.
//

import UIKit

class FLAnimatedImageView: UIImageView {

    var animatedImage: FLAnimatedImage? {
        didSet {
            if self.animatedImage?.isEqual(oldValue) == false {


                if let animatedImage = self.animatedImage {
                    if super.image != nil {
                        // transform을 identity로 바꾸기 위함
                        super.image = self.animatedImage?.posterImage
                        super.image = nil
                    }


                    super.isHighlighted = false

                    self.invalidateIntrinsicContentSize()

                    self.currentFrame = animatedImage.posterImage
                    self.currentFrameIndex = 0

                    if animatedImage.loopCount > 0 {
                        self.loopCountDown = animatedImage.loopCount
                    } else {
                        self.loopCountDown = .max
                    }

                    self.accumulator = 0

                    self.updateShouldAnimate()

                    if self.shouldAnimate {
                        self.startAnimating()
                    }

                    self.layer.setNeedsDisplay()
                } else {
                    self.stopAnimating()
                }
            }
        }
    }
    var loopCompletionBlock: ((Int) -> Void)?

    private(set) var currentFrame: UIImage?
    private(set) var currentFrameIndex: Int = 0

    private var _runLoopMode: RunLoop.Mode = .default

    var runLoopMode: RunLoop.Mode {
        set {
            if ![RunLoop.Mode.default, RunLoop.Mode.common].contains(newValue) {
                self._runLoopMode = .default
            } else {
                self._runLoopMode = newValue
            }
        }

        get {
            return _runLoopMode
        }
    }

    private var loopCountDown: Int = 0
    private var accumulator: TimeInterval = 0
    private var displayLink: CADisplayLink?

    private var shouldAnimate: Bool = false
    private var needsDisplayWhenImageBecomesAvailable: Bool = false

    override var alpha: CGFloat {
        didSet {
            self.updateShouldAnimate()

            if self.shouldAnimate {
                self.startAnimating()
            } else {
                self.stopAnimating()
            }
        }
    }

    override var isHidden: Bool {
        didSet {
            self.updateShouldAnimate()

            if self.shouldAnimate {
                self.startAnimating()
            } else {
                self.stopAnimating()
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        get {
            if self.animatedImage != nil {
                return self.image?.size ?? .zero
            }

            return super.intrinsicContentSize
        }
    }

    override var image: UIImage? {
        set {
            if newValue != nil {
                self.animatedImage = nil
            }

            super.image = newValue
        }

        get {
            if self.animatedImage != nil {
                return self.currentFrame
            } else {
                return super.image
            }
        }
    }

    override var isAnimating: Bool {
        if self.animatedImage != nil,
            let displayLink = self.displayLink {
            return !displayLink.isPaused
        } else {
            return super.isAnimating
        }
    }

    private var frameDelayGreatestCommonDivisor: TimeInterval {
        let kGreatestCommonDivisorPrecision = 2.0 / kFLAnimatedImageDelayTimeIntervalMinimum

        guard let delays = self.animatedImage?.delayTimesForIndices.map({ $0.value }) else { return .zero }

        var scaledGCD: UInt = UInt((delays[0] * kGreatestCommonDivisorPrecision).rounded())

        for value in delays {
            scaledGCD = gcd(UInt((value * kGreatestCommonDivisorPrecision).rounded()), scaledGCD)
        }

        return Double(scaledGCD) / kGreatestCommonDivisorPrecision
    }

    override init(image: UIImage?) {
        super.init(image: image)

        self.commonInit()
    }

    override init(image: UIImage?, highlightedImage: UIImage?) {
        super.init(image: image, highlightedImage: highlightedImage)

        self.commonInit()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

        self.commonInit()
    }

    override func startAnimating() {
        if self.animatedImage != nil {
            if self.displayLink == nil {
                let proxy = DisplayLinkWeakProxy(original: self)

                self.displayLink = CADisplayLink(target: proxy, selector: #selector(displyayDidRefresh(sender:)))

                self.displayLink?.add(to: .main, forMode: self.runLoopMode)
            }

            let kDisplayRefreshRate = 60.0
            self.displayLink?.preferredFramesPerSecond = max(Int(self.frameDelayGreatestCommonDivisor * kDisplayRefreshRate), 1)

            self.displayLink?.isPaused = false
        } else {
            super.startAnimating()
        }
    }

    override func stopAnimating() {
        if self.animatedImage != nil {
            self.displayLink?.isPaused = true
        } else {
            super.stopAnimating()
        }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()

        self.updateShouldAnimate()

        if self.shouldAnimate {
            self.startAnimating()
        } else {
            self.stopAnimating()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        self.updateShouldAnimate()

        if self.shouldAnimate {
            self.startAnimating()
        } else {
            self.stopAnimating()
        }
    }

    private func commonInit() {
        self.runLoopMode = ProcessInfo.processInfo.defaultRunLoopMode

        self.accessibilityIgnoresInvertColors = true
    }

    private func updateShouldAnimate() {
        let isVisible = self.window != nil && self.superview != nil && !self.isHidden && self.alpha > 0

        self.shouldAnimate = self.animatedImage != nil && isVisible
    }
}

fileprivate extension ProcessInfo {
    var defaultRunLoopMode: RunLoop.Mode {
        return self.activeProcessorCount > 1 ? RunLoop.Mode.common : RunLoop.Mode.default
    }
}

fileprivate func gcd<Number: BinaryInteger>(_ a: Number, _ b: Number) -> Number {
    if a < b {
        return gcd(b, a)
    } else if a == b {
        return b
    }

    var a = a
    var b = b

    while true  {
        let remainder = a % b

        if remainder == 0 {
            return b
        }

        a = b
        b = remainder
    }
}

extension FLAnimatedImageView: DisplayLinkRepeatable {
    @objc func displyayDidRefresh(sender: CADisplayLink) {
        guard self.shouldAnimate else { return }

        guard let delayTime = self.animatedImage?.delayTimesForIndices[self.currentFrameIndex] else {
            self.currentFrameIndex += 1
            return
        }

        if let image = self.animatedImage?.imageLazilyCached(at: self.currentFrameIndex) {
            self.currentFrame = image

            if self.needsDisplayWhenImageBecomesAvailable {
                self.layer.setNeedsDisplay()
                self.needsDisplayWhenImageBecomesAvailable = false
            }

            self.accumulator += sender.duration * Double(sender.preferredFramesPerSecond)

            while self.accumulator >= delayTime {
                self.accumulator -= delayTime
                self.currentFrameIndex += 1

                if self.currentFrameIndex >= (self.animatedImage?.frameCount ?? 0) {
                    self.loopCountDown -= 1

                    self.loopCompletionBlock?(self.loopCountDown)

                    if self.loopCountDown == 0 {
                        self.stopAnimating()
                        return
                    }

                    self.currentFrameIndex = 0
                }

                self.needsDisplayWhenImageBecomesAvailable = true
            }
        } else {
            // debug purpose
        }
    }
}
