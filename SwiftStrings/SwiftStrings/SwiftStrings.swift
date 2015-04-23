//
//  SwiftStrings.swift
//  SwiftStrings
//
//  Created by John Holdsworth on 23/04/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//

import Foundation

@objc (SwiftStrings)
class SwiftStrings: NSObject {

    @objc class func convert( stringPtr: UnsafePointer<Void> ) -> NSString {
        let ptr = UnsafePointer<String>( stringPtr )
        return ptr.memory
    }

}
