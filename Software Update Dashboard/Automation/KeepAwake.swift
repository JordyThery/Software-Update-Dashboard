import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps this Mac from sleeping on its own while automatic refresh wants it,
/// and only while the Mac is on power: on battery the hold is released at
/// once and taken again when power comes back. The display may still sleep.
@MainActor
final class KeepAwake {
    /// Whether the Mac runs on power (not on its battery); tests replace it.
    var isOnPower: () -> Bool = { KeepAwake.onPowerNow() }
    /// Takes and releases the system's hold; tests replace them.
    var hold: () -> IOPMAssertionID? = { KeepAwake.takeHold() }
    var release: (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }
    /// Called when the power source changes, so the owner can update.
    var onChange: (() -> Void)?

    private(set) var assertion: IOPMAssertionID?
    private var wanted = false
    private var source: CFRunLoopSource?

    var isHolding: Bool { assertion != nil }

    /// Holds when wanted and on power, else releases.
    func update(wanted: Bool) {
        self.wanted = wanted
        watchPower(wanted)
        if wanted && isOnPower() {
            if assertion == nil { assertion = hold() }
        } else if let held = assertion {
            release(held)
            assertion = nil
        }
    }

    /// The power source changed: check again.
    func powerChanged() {
        update(wanted: wanted)
        onChange?()
    }

    /// Listens for power source changes only while a hold is wanted.
    private func watchPower(_ on: Bool) {
        if on, source == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let created = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let keepAwake = Unmanaged<KeepAwake>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { keepAwake.powerChanged() }
            }, context)?.takeRetainedValue() else { return }
            source = created
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        } else if !on, let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = nil
        }
    }

    nonisolated static func onPowerNow() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    nonisolated static func takeHold() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Software Update Dashboard: automatic refresh" as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }
}
