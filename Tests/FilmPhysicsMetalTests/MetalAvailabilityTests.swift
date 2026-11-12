//
//  MetalAvailabilityTests.swift
//  light suffer胶片 — iOS app
//
//  The fallback of the Metal test target on the platforms that have no
//  Metal.
//
//  Every other file of the target is wrapped in `#if canImport(Metal)`, so
//  the target would be empty on Linux; this file keeps it non empty and
//  reports, honestly, that the Metal tests did not run.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest

// The Metal module is imported only where it exists: the test below uses
// `MTLCreateSystemDefaultDevice()`, which lives in it.
#if canImport(Metal)
import Metal
#endif

final class MetalAvailabilityTests: XCTestCase {

    /// The Metal tests run on the platforms that have a Metal device.
    ///
    /// The test **skips** when there is no device (the CI of the project
    /// runs on macOS, where there is one); it never fails for the absence
    /// of a device — only the compilation of the shaders is a failure.
    func testTheMetalDeviceIsAvailable() throws {
        #if canImport(Metal)
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal not available: no MTLDevice")
        }
        #else
        throw XCTSkip("Metal not available: this platform has no Metal")
        #endif
    }
}
