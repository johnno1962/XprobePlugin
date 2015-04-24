//
//  SwiftStrings.swift
//  SwiftStrings
//
//  Created by John Holdsworth on 23/04/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//

import Foundation

@objc (XprobeSwift)
class XprobeSwift: NSObject {

    @objc class func convert( stringPtr: UnsafePointer<Void> ) -> NSString {
        return UnsafePointer<String>( stringPtr ).memory
    }

}
