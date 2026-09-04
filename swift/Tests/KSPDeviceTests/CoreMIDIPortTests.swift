import Testing

@testable import KSPDevice

/// The one suite that touches CoreMIDI itself. It asks for a name nothing publishes, so it
/// answers the same on a workbench with the device attached and on a runner with no MIDI at all.
@Suite struct CoreMIDIPortTests {
    @Test func anAbsentDeviceFailsBeforeAnythingIsOpened() {
        let missing = "KeyStep Pro (no such endpoint)"

        #expect(throws: DeviceError.notAttached(missing)) { try CoreMIDIPort(named: missing) }
    }

    @Test func theMessageNamesTheFix() {
        let error = DeviceError.notAttached(KeyStepPro.endpointName)

        #expect(error.description.contains("KeyStep Pro"))
        #expect(error.description.contains("plugged in over USB and powered on"))
    }
}
