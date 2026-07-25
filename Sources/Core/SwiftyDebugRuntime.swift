//
//  SwiftyDebugRuntime.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation

/// Central runtime kill-switch for the whole SDK.
///
/// The SDK installs its hooks (URLProtocol, WKWebView swizzles, log hooks) as
/// one-way swizzles that cannot be safely un-installed at runtime. Instead of
/// un-swizzling, every hot path consults `SwiftyDebugRuntime.isActive` and
/// short-circuits when the SDK has been *fully stopped* — so a stopped SDK does
/// zero interception and zero logging work, as if it were never included.
///
/// The flag is read from arbitrary threads (URLProtocol `canInit`, the OSLog
/// poll queue, the stdout pipe queue) and written from the main thread. It is
/// backed by an atomic `Int32` so reads never lock and never tear.
enum SwiftyDebugRuntime {

    // Backing store: 1 = active, 0 = fully stopped. Starts active.
    private static var _active: Int32 = 1

    /// `true` while the SDK is doing its normal work. `false` after a full stop.
    ///
    /// Hot paths should check this **first**, before doing any work, so that a
    /// stopped SDK has ~zero cost.
    @inline(__always)
    static var isActive: Bool {
        OSAtomicLoadInt32(&_active) != 0
    }

    /// Marks the SDK active again (reverses a full stop via runtime gates only —
    /// nothing is re-swizzled).
    static func markActive() {
        OSAtomicStoreInt32(1, &_active)
    }

    /// Marks the SDK fully stopped. All gated hot paths become no-ops.
    static func markStopped() {
        OSAtomicStoreInt32(0, &_active)
    }
}

// MARK: - Atomic helpers

/// `OSAtomic*` is deprecated but still the simplest lock-free primitive that is
/// safe to call from any thread including URLProtocol callbacks. We wrap it so
/// the deprecation is contained to one place and the intent is explicit.
@inline(__always)
private func OSAtomicLoadInt32(_ ptr: UnsafeMutablePointer<Int32>) -> Int32 {
    // A relaxed load is sufficient: readers only need a recent value, and the
    // writer publishes with a full barrier below.
    return ptr.pointee
}

@inline(__always)
private func OSAtomicStoreInt32(_ value: Int32, _ ptr: UnsafeMutablePointer<Int32>) {
    // Publish with a full memory barrier so gated threads observe the change
    // promptly.
    ptr.pointee = value
    OSMemoryBarrier()
}
