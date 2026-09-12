import Foundation

/// A drum-map config path that cannot exist, so a run never picks up a personal one.
let noPersonalConfig = URL(filePath: "/nonexistent/keysteppro/drum_map.json")

func tempFile(_ contents: String, suffix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ksp-\(UUID().uuidString)\(suffix)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
}
