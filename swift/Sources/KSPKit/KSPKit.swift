/// Namespace for the KeyStep Pro format core, the port of `src/ksp/`.
///
/// M9 landed the leaf layers, in dependency order: ``Constants``, ``Keys``, ``LenientJSON`` and
/// the diagnostics types. The model and the reader are M10. This target takes no third-party
/// dependencies, and that is load-bearing: it is what keeps the port testable on Linux. See
/// `Package.swift`.
public enum KSPKit {
    /// The `device` value every `.KeyStepPro` file opens with.
    public static let deviceName = "KeyStepPro"
}
