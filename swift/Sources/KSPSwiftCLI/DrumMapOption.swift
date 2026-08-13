import Foundation
import KSPKit

/// Shared `--drum-map` handling. A port of `src/ksp_cli/drum_map_option.py`.
///
/// Every command that resolves a drum lane has to answer the same question -- which lane plays
/// which MIDI note -- and the answer is a device global the project file does not carry. One
/// grammar and one config file, so a user who sets it up once is understood by all of them.

/// Where a user's own drum map lives, if they have one. Path resolution stays in the CLI: `KSPKit`
/// must not decide where files are.
let drumMapConfigPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/keysteppro/drum_map.json")

let drumMapHelp = """
    lane -> note mapping: chromatic:N, custom:a,b,c (24 notes) or none. The device's drum map is a \
    global setting and is not in the project file, so this defaults to \
    chromatic:\(DrumMap.defaultChromaticLow)
    """

/// Parse a `--drum-map` argument.
///
/// `chromatic:36` | `custom:36,38,42,...` | `none`. `nil` means do not resolve lanes at all, which
/// is the honest output when the user's device settings are unknown and they would rather see the
/// raw lane number.
func parseDrumMap(_ spec: String) throws -> DrumMap? {
    if spec == "none" { return nil }
    let kind = spec.prefix { $0 != ":" }
    let rest = String(spec.dropFirst(kind.count).dropFirst())
    switch kind {
    case "chromatic":
        return rest.isEmpty
            ? try DrumMap.chromatic() : try DrumMap.chromatic(int(rest, "chromatic low note"))
    case "custom":
        return try DrumMap.custom(rest.split(separator: ",").map { try int($0, "custom note") })
    default:
        throw KSPError.value(
            "unknown drum map '\(spec)'; expected chromatic:N, custom:a,b,c or none")
    }
}

private func int(_ text: some StringProtocol, _ what: String) throws -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let value = Int(trimmed) else {
        throw KSPError.value("\(what) '\(trimmed)' is not a number")
    }
    return value
}

/// Pick the drum map: the flag wins, then the config file, then the default.
///
/// `configPath` is passed in by the caller rather than read from this file, so a test can point it
/// somewhere harmless instead of depending on whether the machine running the suite happens to
/// have a personal config.
func resolveDrumMap(_ spec: String?, configPath: URL) throws -> DrumMap? {
    if let spec { return try parseDrumMap(spec) }
    guard let data = try? Data(contentsOf: configPath) else {
        return try DrumMap.chromatic()
    }
    do {
        return try DrumMap.from(JSONDecoder().decode(DrumMapConfig.self, from: data))
    } catch let error as KSPError {
        throw error
    } catch {
        // Named, because it is the config file rather than the flag that is malformed.
        throw KSPError.value("\(configPath.path): \(error.localizedDescription)")
    }
}
