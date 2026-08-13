import Foundation
import KSPKit

/// Rendering a project as an indented tree. A port of the formatting half of `src/ksp_cli/dump.py`.
///
/// Everything printed here is decoded by ``KSPKit/Reader``; this only formats.

/// Widest gate the ladder prints, `0.0625`. Fixed so the columns after gate stay aligned across a
/// pattern.
private let gateWidth = 6

/// Show the gate length in steps, or the raw value when it does not decode.
///
/// The ladder covers every legal value, so `?` now means the file holds a gate outside 0-127.
/// Printing the raw number beats printing the nearest rung, which would look authoritative and be
/// wrong.
private func formatGate(_ gate: Double?, raw: Int) -> String {
    guard let gate else { return "?(\(raw))" }
    return general(gate).rightAligned(to: gateWidth)
}

private func formatSkip(_ skip: [Int]) -> String {
    if skip.count == Constants.skipSequences.count { return "always" }
    if skip.isEmpty { return "never" }
    return skip.map(String.init).joined(separator: ",")
}

/// Why this note will not play, or `""` when it will.
///
/// Two mechanisms, both toggled the same way on the device, so both read as "disabled" and name
/// their reason rather than inventing separate words.
private func disabledMarker(_ note: Note, lastStep: Int?) -> String {
    if !note.active { return "  [DISABLED: step turned off]" }
    if let lastStep, note.step > lastStep { return "  [DISABLED: past last step]" }
    return ""
}

/// Root note and scale, both decoded by protocol T5.6.
private func scaleLine(_ pattern: Pattern) -> String {
    let scale = pattern.scaleName ?? "scale \(pattern.scale) (off the device's list)"
    return "      root \(Constants.rootNoteName(pattern.rootNote))   scale \(scale)"
}

private func patternLines(_ pattern: Pattern, _ drumMap: DrumMap?, verbose: Bool) -> [String] {
    var lines = ["    Pattern \(String(pattern.number).padded(to: 2)) [\(pattern.mode.rawValue)]"]
    if pattern.rootNote != 0 || pattern.scale != 0 {
        // Only when set: every sample project reads C chromatic, and a line printed on all 16
        // patterns of all 4 tracks would be noise.
        lines.append(scaleLine(pattern))
    }

    // A pattern's melodic and drum sets each have their own step count and swing, so each is
    // printed against the notes it governs rather than as a single pair of numbers whose owner
    // would be ambiguous.
    for kind in NoteKind.allCases {
        let notes = pattern.notes(of: kind)
        if notes.isEmpty { continue }

        let steps: Int?
        let swing: Int?
        if kind == .drum {
            (steps, swing) = (pattern.drumStepCount, pattern.drumSwingPercent)
            if let drumMap {
                // Said next to the notes it governs, and said every time, because a resolved drum
                // note is an assumption about the user's device rather than anything read from
                // their file.
                lines.append("      drum map: \(drumMap.describe())")
            }
        } else {
            (steps, swing) = (pattern.seqStepCount, pattern.seqSwingPercent)
        }
        let bits = pattern.bits(kind)
        let rhythm = bits.polyrhythm ? "poly" : "mono"
        lines.append(
            "      \(kind.rawValue): \(steps.map(String.init) ?? "None") steps, \(bits.label), "
                + "swing \(swing.map(String.init) ?? "None")%, \(bits.direction.rawValue), \(rhythm)"
        )
        let width = kind == .drum && drumMap != nil ? 30 : 10
        for slot in Set(notes.map(\.slot)).sorted() {
            lines.append("        slot \(slot)")
            for note in notes where note.slot == slot {
                let shift = note.timeShift == 0 ? " 0" : String(format: "%+d", note.timeShift)
                lines.append(
                    "          note \(String(note.index).rightAligned(to: 2))  "
                        + "step \(String(note.step).rightAligned(to: 2))  "
                        + "\(note.labelled(drumMap).padded(to: width)) "
                        + "vel \(String(note.velocity).rightAligned(to: 3))  "
                        + "gate \(formatGate(note.gate, raw: note.gateRaw))  "
                        + "shift \(shift)  rand \(String(note.randomness).rightAligned(to: 3))  "
                        + "seq \(formatSkip(note.skip))"
                        // Only ever marked when the note will not play: that is the surprise, an
                        // audible note is the norm.
                        + disabledMarker(note, lastStep: steps))
            }
        }
    }
    if verbose {
        // Inline, next to the notes they are about. Collapsed they would lose the one thing a tree
        // dump is for: where the problem is.
        lines += pattern.warnings.map { "      ! \($0)" }
    }
    return lines
}

private func trackLines(
    _ track: Track, showAll: Bool, drumMap: DrumMap?, verbose: Bool
) -> [String] {
    let patterns = track.patterns.filter { showAll || !$0.isEmpty }
    if patterns.isEmpty { return [] }
    let mode = track.drumMode ? "  [drum mode]" : ""
    return ["  Track \(track.number) (item \(track.itemID))\(mode)"]
        + patterns.flatMap { patternLines($0, drumMap, verbose: verbose) }
}

/// Every diagnostic in the project, stamped with the track it came from.
func projectReport(_ project: Project) -> Report {
    let collector = Collector()
    collector.extend(project.diagnostics.entries)
    for track in project.tracks {
        for pattern in track.patterns {
            collector.extend(pattern.diagnostics.entries.map { $0.at(track: track.number) })
        }
    }
    return collector.report()
}

/// Render a project as an indented tree: tracks -> patterns -> notes.
func formatProject(
    _ project: Project, showAll: Bool = false, drumMap: DrumMap? = nil, verbose: Bool = false
) -> String {
    var lines = [
        project.sourceName.isEmpty ? project.device : project.sourceName,
        "  device \(project.device)   version \(project.version ?? "(none)")",
        "  tempo \(general(project.tempoBPM)) BPM   "
            + "swing \(project.globalSwingPercent)%   scene \(project.currentScene)",
    ]
    // Only scenes that chain something: a project nobody has chained holds the sentinel in all 16
    // slots of all 5 tracks of all 16 scenes.
    for scene in project.chainedScenes {
        for chain in scene.chains {
            let patterns = chain.patterns.map(String.init).joined(separator: " -> ")
            lines.append("  scene \(scene.number) track \(chain.track) chain: \(patterns)")
        }
    }
    if verbose {
        lines += project.warnings.map { "  ! \($0)" }
    }
    lines.append("")

    let body = project.tracks.flatMap {
        trackLines($0, showAll: showAll, drumMap: drumMap, verbose: verbose)
    }
    lines += body.isEmpty ? ["  (no patterns hold notes)"] : body

    if !verbose {
        // One block at the end rather than a line beside every pattern: the notes are what the
        // dump is for, and the same finding recurs in a dozen patterns.
        let report = projectReport(project)
        if !report.isEmpty {
            lines.append("")
            lines += report.render().map { "  ! \($0)" }
            if let note = report.note() {
                lines.append("  (\(note))")
            }
        }
    }
    return lines.joined(separator: "\n")
}

/// Python's `f"{value:g}"`: the shortest of fixed and exponential, with no trailing zeros, so
/// 120.0 prints as `120` and 0.1875 as `0.1875`.
private func general(_ value: Double) -> String {
    String(format: "%g", value)
}

extension String {
    /// Python's `str.ljust`, which pads on the right and never truncates.
    fileprivate func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }

    /// Python's `str.rjust`.
    fileprivate func rightAligned(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
