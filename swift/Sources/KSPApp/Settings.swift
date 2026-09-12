import Foundation
import KSPMIDI
import KSPRun

struct DrumSense: Equatable, Sendable {
    let designation: DrumDesignation
    let channel: Int
}

struct Settings: Sendable, Equatable, Codable {
    static let repeatRange = 1...MIDIExport.maxRepeat

    static let drumChannelRange = KSPMIDI.channels

    enum Drums: String, CaseIterable, Identifiable, Codable, Sendable {
        case automatic
        case none

        var id: String { rawValue }
        var label: String { self == .automatic ? "Automatic" : "None" }
    }

    enum StepSkip: String, CaseIterable, Identifiable, Codable, Sendable {
        case auto
        case one = "1"
        case two = "2"
        case three = "3"
        case four = "4"

        var id: String { rawValue }
        var passes: Int? { Int(rawValue) }
        var label: String { self == .auto ? "Auto" : rawValue }
    }

    var dryRun = false
    var verbose = false
    var stepSkip: StepSkip = .auto
    var repeatCount = 1
    var cells: [Int: Set<Int>] = [:]
    var midiTracksSpec: String?
    var routeSpec: String?
    var drumTrack: Int?
    var drums: Drums = .automatic
    /// Counting from 1 as the CLI counts it; the core takes it from 0.
    var drumChannel = MIDIImport.drumChannel + 1
    var splitPerPattern = false

    var replaceVelocity = false
    var replaceSwing = false
    var replaceTimeShift = false

    var ignoreVelocity = false
    var ignoreSwing = false
    var ignoreTimeShift = false

    func selecting(_ selection: GridSelection) -> Settings {
        var copy = self
        copy.cells = selection.selectedCells
        return copy
    }

    func selecting(_ selection: SourceTrackSelection) -> Settings {
        var copy = self
        copy.midiTracksSpec = selection.spec
        copy.routeSpec = selection.routeSpec
        copy.drumTrack = selection.drumTrack
        return copy
    }

    func drumSense(named track: Int?) -> DrumSense {
        DrumSense(
            designation: track.map(DrumDesignation.source) ?? (drums == .none ? .none : .auto),
            channel: drumChannel)
    }

    func convertOptions(source: URL, output: URL?) -> ConvertRunner.Options {
        ConvertRunner.Options(
            paths: [source], output: output, drumTrack: drumTrack,
            noDrums: drums == .none && drumTrack == nil, drumChannel: drumChannel - 1,
            routeSpec: routeSpec,
            fitSwing: !ignoreSwing,
            fitTimeShift: !ignoreTimeShift, midiTracksSpec: midiTracksSpec,
            flatVelocitySpec: ignoreVelocity ? freshVelocitySpec : nil,
            dryRun: dryRun, verbose: verbose, configPath: drumMapConfigPath)
    }

    func exportOptions(source: URL, output: URL?) -> ExportRunner.Options {
        ExportRunner.Options(
            path: source, output: output, split: splitPerPattern, cells: cells,
            passes: stepSkip.passes, repeatCount: repeatCount,
            flatVelocity: replaceVelocity ? MIDIExport.defaultFlatVelocity : nil,
            applySwing: !replaceSwing, applyTimeShift: !replaceTimeShift, dryRun: dryRun,
            verbose: verbose, configPath: drumMapConfigPath)
    }

    private enum CodingKeys: String, CodingKey {
        case stepSkip
        case repeatCount
        case drums
        case drumChannel
        case splitPerPattern
        case replaceVelocity
        case replaceSwing
        case replaceTimeShift
        case ignoreVelocity
        case ignoreSwing
        case ignoreTimeShift
    }
}

extension Settings {
    init(from decoder: Decoder) throws {
        let blob = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = Settings()
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try blob.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init()
        stepSkip = try read(.stepSkip, fresh.stepSkip)
        repeatCount = try read(.repeatCount, fresh.repeatCount)
        drums = try read(.drums, fresh.drums)
        drumChannel = try read(.drumChannel, fresh.drumChannel)
        splitPerPattern = try read(.splitPerPattern, fresh.splitPerPattern)
        replaceVelocity = try read(.replaceVelocity, fresh.replaceVelocity)
        replaceSwing = try read(.replaceSwing, fresh.replaceSwing)
        replaceTimeShift = try read(.replaceTimeShift, fresh.replaceTimeShift)
        ignoreVelocity = try read(.ignoreVelocity, fresh.ignoreVelocity)
        ignoreSwing = try read(.ignoreSwing, fresh.ignoreSwing)
        ignoreTimeShift = try read(.ignoreTimeShift, fresh.ignoreTimeShift)
    }
}
