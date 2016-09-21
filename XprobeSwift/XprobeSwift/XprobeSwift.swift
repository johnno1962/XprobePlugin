//
//  XprobeSwift.swift
//  XprobeSwift
//
//  Created by John Holdsworth on 23/04/2015.
//  Copyright (c) 2015 John Holdsworth. All rights reserved.
//

import Foundation

#if swift(>=3.0)
// not public in Swift3
@warn_unused_result
@_silgen_name("swift_demangle")
public
func _stdlib_demangleImpl(
    mangledName: UnsafePointer<UInt8>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<UInt8>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
    ) -> UnsafeMutablePointer<CChar>?

@warn_unused_result
func _stdlib_demangleName(_ mangledName: String) -> String {
    return mangledName.nulTerminatedUTF8.withUnsafeBufferPointer {
        (mangledNameUTF8) in

        let demangledNamePtr = _stdlib_demangleImpl(
            mangledName: mangledNameUTF8.baseAddress,
            mangledNameLength: UInt(mangledNameUTF8.count - 1),
            outputBuffer: nil,
            outputBufferSize: nil,
            flags: 0)

        if let demangledNamePtr = demangledNamePtr {
            let demangledName = String(cString: demangledNamePtr)
            free(demangledNamePtr)
            return demangledName
        }
        return mangledName
    }
}
#endif

@objc (XprobeSwift)
class XprobeSwift: NSObject {

    #if swift(>=3.0)
    @objc class func string( _ stringPtr: UnsafePointer<Void> ) -> NSString {
            return "\"\(UnsafePointer<String>( stringPtr ).pointee)\"" as NSString
    }

    @objc class func stringOpt( _ stringPtr: UnsafePointer<Void> ) -> NSString {
        if let string = UnsafePointer<String?>( stringPtr ).pointee {
            return "\"\(string)\"" as NSString
        } else {
            return "nil"
        }
    }

    @objc class func array( _ arrayPtr: UnsafePointer<Void> ) -> NSString {
        let array = UnsafePointer<Array<AnyObject>>( arrayPtr ).pointee
        let s = array.count == 1 ? "" : "s"
        return "[\(array.count) element\(s)]" as NSString
    }

    @objc class func arrayOpt( _ arrayPtr: UnsafePointer<Void> ) -> NSString {
        if let array = UnsafePointer<Array<AnyObject>?>( arrayPtr ).pointee {
            let s = array.count == 1 ? "" : "s"
            return "[\(array.count) element\(s)]" as NSString
        } else {
            return "nil"
        }
    }

    @objc class func demangle( _ name: NSString ) -> NSString {
        return _stdlib_demangleName(name as String) as NSString
    }

    #else

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

    #endif
}
