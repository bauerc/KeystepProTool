/// Namespace for the KeyStep Pro format core, the port of `src/ksp/`.
///
/// Empty until M9, which lands the leaf layers in dependency order: constants, keys, lenient
/// JSON, diagnostics. This target takes no third-party dependencies, and that is load-bearing:
/// it is what keeps the port testable on Linux. See `Package.swift`.
public enum KSPKit {
    /// The `device` value every `.KeyStepPro` file opens with.
    public static let deviceName = "KeyStepPro"
}
