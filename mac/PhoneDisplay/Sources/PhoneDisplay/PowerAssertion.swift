import Foundation
import IOKit.pwr_mgt

final class PowerAssertion {
    private var id: IOPMAssertionID = 0

    func start() {
        guard id == 0 else { return }
        let reason = "PhoneDisplay is streaming to a phone" as CFString
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
    }

    func stop() {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}
