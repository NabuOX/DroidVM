// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVMCore -- platform-independent domain types and the interfaces that separate
// DroidVM's orchestration from its engine.
//
// WHY THIS IS A SEPARATE, APPLE-FREE PACKAGE
//
// DroidVM is developed on Windows, with no local Mac. Anything that can only be
// built on macOS is invisible until CI runs, and CI is slow. So the *decisions* --
// the lifecycle vocabulary, the evidence model, the interfaces the engine must
// satisfy -- live here, where they can be built and tested on any platform with a
// Swift toolchain:
//
//     swift test
//
// That is gate 1 of the build strategy: host-independent tests, runnable from the
// development machine. It deliberately imports nothing from SwiftUI, UIKit, Combine,
// Metal or Foundation's Apple-only corners, so it stays portable.
//
// The iOS app target and the engine live outside this package. See ARCHITECTURE.md.

import PackageDescription

let package = Package(
    name: "DroidVMCore",
    // Declared for the eventual iOS consumer; ignored on non-Apple platforms.
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DroidVMCore", targets: ["DroidVMCore"]),
    ],
    targets: [
        .target(
            name: "DroidVMCore",
            path: "Sources/DroidVMCore"
        ),
        .testTarget(
            name: "DroidVMCoreTests",
            dependencies: ["DroidVMCore"],
            path: "Tests/DroidVMCoreTests"
        ),
    ]
)
