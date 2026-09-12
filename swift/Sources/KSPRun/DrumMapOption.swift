import Foundation
import KSPKit

public let drumMapConfigPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/keysteppro/drum_map.json")

/// `chromatic:36` | `custom:36,38,42,...` | `none`. `nil` means do not resolve lanes at all.
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
        throw KSPError.value("\(configPath.path): \(error.localizedDescription)")
    }
}

/// As `export`'s, except that unset means *fit to the source*: drums outside 36-59 would
/// otherwise be dropped as unmapped.
func resolveImportDrumMap(_ spec: String?, configPath: URL) throws -> DrumMap? {
    if spec == "none" {
        throw KSPError.value(
            "a drum note stores a lane, not a pitch, so importing drums needs a map; use "
                + "chromatic:N or custom:a,b,c, or leave --drum-map off to fit one")
    }
    if let spec { return try parseDrumMap(spec) }
    guard let data = try? Data(contentsOf: configPath) else { return nil }
    return try DrumMap.from(JSONDecoder().decode(DrumMapConfig.self, from: data))
}
