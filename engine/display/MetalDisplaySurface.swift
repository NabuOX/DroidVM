// SPDX-License-Identifier: GPL-2.0-or-later
//
// DroidVM's display backend.
//
// STATUS: written in Phase 1, NOT COMPILED and NOT RUN. It needs Metal, a CAMetalLayer and
// a device.
//
// WHAT IT IS RESPONSIBLE FOR
//
// Binding a host surface to the engine's display path, presenting frames that arrive from
// the guest, and *counting every stage of that journey*. The counters are the point: a
// single frame rate cannot distinguish "the guest is not drawing" from "we are dropping
// everything", and those have opposite fixes.
//
// The counting itself is not done here. This reads the engine's counters -- which the
// C-side listener maintains, one increment per stage -- and hands them to the portable
// tracker, which does the classification. Keeping the *rules* portable is what makes them
// testable; this file only has to be the eyes.

import Foundation
import DroidVMCore
import Metal
import QuartzCore

/// A `DisplayBackend` over a `CAMetalLayer`.
///
/// `@unchecked Sendable`, with the reason stated because the brief permits the attribute only
/// when there is one: every `CAMetalLayer` in this app is mutated from the main thread, the
/// layer is not safe to touch from another, and the only alternative would be a lock on the
/// present path -- which this project refuses to pay. The discipline is single-threaded
/// access, not thread-safety, and saying so is more honest than a lock that would suggest
/// otherwise.
public final class MetalDisplaySurface: DisplayBackend, @unchecked Sendable {

    /// The layer the engine draws into.
    ///
    /// Exactly one. The reference implementation discovered that a second view orphans the
    /// EGL surface, and the only symptom was a frame counter climbing against a black
    /// screen -- which looks like progress.
    public let layer: CAMetalLayer

    private let device: MTLDevice
    private var attachedFlag = false


    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device else { return nil }
        self.device = device

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        // Set by the app once the view has a size. Zero here, and a zero-sized drawable is
        // one of the ways a frame is silently dropped.
        layer.drawableSize = .zero
        self.layer = layer
    }

    // MARK: DisplayBackend

    public func attach(surface: DisplaySurfaceHandle) async throws {
        guard let bound = surface as? MetalSurfaceHandle else {
            throw DisplayAttachmentError.wrongSurfaceKind(
                "expected a MetalSurfaceHandle, got \(type(of: surface))")
        }
        bound.layer.device = device
        bound.layer.pixelFormat = .bgra8Unorm
        bound.layer.framebufferOnly = true

        // Tell the engine a surface exists. The engine cannot discover a CAMetalLayer by
        // itself, and without this the display listener registers against nothing.
        droidvm_display_set_attached(1)

        let registered = droidvm_display_register()
        guard registered == 0 else {
            droidvm_display_set_attached(0)
            throw DisplayAttachmentError.alreadyRegistered(
                "a display listener is already registered; a second one would orphan the "
                + "first surface")
        }

        attachedFlag = true
    }

    public func detach() async {
        guard attachedFlag else { return }
        attachedFlag = false
        droidvm_display_set_attached(0)
        // The engine keeps running: losing the surface is not losing the machine, and a
        // machine that is stopped because someone backgrounded the app is a machine that has
        // to boot again.
    }

    public var attached: Bool { attachedFlag }

    public var counters: DisplayCounters {
        var raw = droidvm_display_counters()
        droidvm_display_read(&raw)
        return DisplayCounters(entered: raw.entered,
                               received: raw.received,
                               presented: raw.presented,
                               dropped: raw.dropped,
                               noScanout: raw.no_scanout,
                               presentFailure: raw.present_failure)
    }

    /// Whether the engine's and Swift's views of the counter struct agree.
    ///
    /// Checked once at startup rather than assumed. A layout mismatch would produce
    /// plausible, wrong numbers -- which is worse than a crash, because it would be believed.
    public static func checkBridgeLayout() -> (ok: Bool, detail: String) {
        let swiftSize = MemoryLayout<droidvm_display_counters>.size
        let cSize = Int(droidvm_display_counters_sizeof())
        return (swiftSize == cSize,
                "droidvm_display_counters: Swift \(swiftSize) bytes, C \(cSize) bytes")
    }

    /// The current drawable size, which the app sets once the view is laid out.
    ///
    /// Exposed because a zero-sized drawable is a silent drop, and the graphics health
    /// monitor needs to be able to see it rather than infer it.
    public var drawableSize: CGSize {
        get { layer.drawableSize }
        set { layer.drawableSize = newValue }
    }
}

/// The host surface handed to the engine.
public final class MetalSurfaceHandle: DisplaySurfaceHandle {
    public let layer: CAMetalLayer
    public init(layer: CAMetalLayer) { self.layer = layer }
}

public enum DisplayAttachmentError: Error, CustomStringConvertible {
    case wrongSurfaceKind(String)
    case alreadyRegistered(String)

    public var description: String {
        switch self {
        case .wrongSurfaceKind(let s): return "wrong surface kind: \(s)"
        case .alreadyRegistered(let s): return s
        }
    }
}
