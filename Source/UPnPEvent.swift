//
//  UPnPEvent.swift
//  ControlPointDemo
//
//  Created by David Robles on 12/21/14.
//  Copyright (c) 2014 David Robles. All rights reserved.
//

import Foundation

@objc class UPnPEvent {
    let rawEventInfo: [String: String]
    init(rawEventInfo: [String: String]) {
        self.rawEventInfo = rawEventInfo
    }
}