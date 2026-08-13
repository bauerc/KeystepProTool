import Testing

@testable import KSPKit

@Test func deviceNameMatchesTheFileDialect() {
    #expect(KSPKit.deviceName == "KeyStepPro")
}
