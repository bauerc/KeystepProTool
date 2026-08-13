import KSPKit
import KSPMIDI

// The headless face of the port, so M9-M12 are testable long before M13's GUI exists. Grows a
// `dump` subcommand at M10, then `export` and `convert` at M12; argument parsing arrives with them.
print("ksp-swift-cli: \(KSPKit.deviceName) tools, \(KSPMIDI.defaultTicksPerQuarterNote) ppq")
