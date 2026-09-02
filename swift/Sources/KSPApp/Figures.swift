/// Rule 3 sets every figure in SF Mono, but a finding is prose the core wrote, so its figures have
/// to be found rather than formatted. Cutting the string keeps wrapping and selection that an
/// `HStack` of `Text` would lose.
enum Figures {
    struct Run: Equatable {
        let text: String
        let isFigure: Bool
    }

    private static let noteLetters: Set<Character> = ["A", "B", "C", "D", "E", "F", "G"]
    private static let signs: Set<Character> = ["+", "-", "\u{2212}"]

    /// Total and lossless: the runs joined back together are the string that went in.
    static func split(_ text: String) -> [Run] {
        let characters = Array(text)
        var runs: [Run] = []
        var prose = ""
        var index = 0

        while index < characters.count {
            guard let end = figure(in: characters, from: index) else {
                prose.append(characters[index])
                index += 1
                continue
            }
            if !prose.isEmpty {
                runs.append(Run(text: prose, isFigure: false))
                prose = ""
            }
            runs.append(Run(text: String(characters[index..<end]), isFigure: true))
            index = end
        }
        if !prose.isEmpty { runs.append(Run(text: prose, isFigure: false)) }
        return runs
    }

    /// Where the figure starting at `start` ends, or `nil` if none starts there.
    private static func figure(in characters: [Character], from start: Int) -> Int? {
        var index = start
        let digit = { (offset: Int) in
            offset < characters.count && characters[offset].isASCII
                && characters[offset].isNumber
        }
        // A sign or a note letter is only a figure's head where a word does not run into it, so
        // the `2` of `mid2` is a figure and the `d` before it is not part of one.
        let detached =
            start == 0 || !(characters[start - 1].isLetter || characters[start - 1].isNumber)

        if detached, noteLetters.contains(characters[start]) {
            let sharp = index + 1 < characters.count && characters[index + 1] == "#"
            let head = sharp ? index + 2 : index + 1
            guard digit(head) else { return nil }
            index = head
        } else if detached, signs.contains(characters[start]) {
            guard digit(index + 1) else { return nil }
            index += 1
        } else if !digit(index) {
            return nil
        }

        while digit(index) {
            index += 1
            // A `.` or a `/` continues the figure only between digits: `0.5`, `16/32/48/64`.
            if index < characters.count, characters[index] == "." || characters[index] == "/",
                digit(index + 1)
            {
                index += 1
            }
        }
        return index
    }
}
