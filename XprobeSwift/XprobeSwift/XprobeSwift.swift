//
//  XprobeSwift.swift
//  XprobeSwift
//
//  Created by John Holdsworth on 23/04/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//

import Foundation

@objc (XprobeSwift)
class XprobeSwift: NSObject {

    @objc class func string( stringPtr: UnsafePointer<Void> ) -> NSString {
        return "\"\(UnsafePointer<String>( stringPtr ).memory)\""
    }

    @objc class func stringOpt( stringPtr: UnsafePointer<Void> ) -> NSString {
        if let string = UnsafePointer<String?>( stringPtr ).memory {
            return "\"\(string)\""
        } else {
            return "nil"
        }
    }

    @objc class func array( arrayPtr: UnsafePointer<Void> ) -> NSString {
        let array = UnsafePointer<Array<AnyObject>>( arrayPtr ).memory
        let s = array.count == 1 ? "" : "s"
        return "[\(array.count) element\(s)]"
    }

    @objc class func arrayOpt( arrayPtr: UnsafePointer<Void> ) -> NSString {
        if let array = UnsafePointer<Array<AnyObject>?>( arrayPtr ).memory {
            let s = array.count == 1 ? "" : "s"
            return "[\(array.count) element\(s)]"
        } else {
            return "nil"
        }
    }

    @objc class func demangle( name: NSString ) -> NSString {
        return _stdlib_demangleName(name as String)
    }

}
