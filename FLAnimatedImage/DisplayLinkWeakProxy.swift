//
//  DisplayLinkWeapProxy.swift
//  FLAnimatedImage
//
//  Created by Joshua on 2020/12/27.
//  Copyright © 2020 com.flipboard. All rights reserved.
//

import Foundation
import UIKit

@objc protocol DisplayLinkRepeatable: NSObjectProtocol {
    @objc func displyayDidRefresh(sender: CADisplayLink)
}

final class DisplayLinkWeakProxy: NSObject, DisplayLinkRepeatable {
    weak var original: DisplayLinkRepeatable?

    init(original: DisplayLinkRepeatable? = nil) {
        self.original = original
    }

    @objc func displyayDidRefresh(sender: CADisplayLink) {
        original?.displyayDidRefresh(sender: sender)
    }
}
