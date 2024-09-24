// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
//  $Id: //depot/XprobePlugin/Package.swift#16 $
//

import PackageDescription
import Foundation

let package = Package(
    name: "XprobePlugin",
    platforms: [.macOS("10.12"), .iOS("10.0"), .tvOS("10.0")],
    products: [
        .library(name: "Xprobe", targets: ["Xprobe"]),
        .library(name: "XprobeSweep", targets: ["XprobeSweep"]),
        .library(name: "XprobeSwift", targets: ["XprobeSwift"]),
        .library(name: "XprobeUI", targets: ["XprobeUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/johnno1962/SwiftTrace",
                 .upToNextMajor(from: "8.6.0")),
    ],
    targets: [
        .target(name: "Xprobe", dependencies: ["XprobeSwift"]),
        .target(name: "XprobeSweep", dependencies: []),
        .target(name: "XprobeSwift", dependencies: ["XprobeSweep",
            .product(name: "SwiftTraceD", package: "SwiftTrace")]),
        .target(name: "XprobeUI", dependencies: []),
    ]
)
