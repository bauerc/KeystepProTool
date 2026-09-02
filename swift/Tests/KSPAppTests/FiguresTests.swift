import KSPKit
import Testing

@testable import KSPApp

@Suite struct FiguresTests {
    private func figures(in text: String) -> [String] {
        Figures.split(text).filter(\.isFigure).map(\.text)
    }

    /// The property the view depends on: a run is a slice of the string, so rebuilding the line
    /// from its runs cannot lose or invent a character.
    @Test func acutStringJoinsBackIntoItself() {
        let corpus =
            Diagnostics.summaries.values.map(\.template) + [
                "", "no digits at all", "0.5", "C3", "16/32/48/64", "−4 … +50", "192",
                "M6-song.mid",
            ]

        for text in corpus {
            #expect(Figures.split(text).map(\.text).joined() == text)
        }
    }

    @Test func adeviceFigureComesBackWhole() {
        #expect(figures(in: "a gate of 0.5 steps") == ["0.5"])
        #expect(figures(in: "shifted −4 ticks") == ["−4"])
        #expect(figures(in: "swing +50 percent") == ["+50"])
        #expect(figures(in: "the 16/32/48/64 sequences") == ["16/32/48/64"])
        #expect(figures(in: "middle C3 here") == ["C3"])
        #expect(figures(in: "lane F#2 here") == ["F#2"])
    }

    @Test func aprosaicStringIsOneRunAndAnEmptyOneIsNoRuns() {
        #expect(
            Figures.split("the device has four tracks") == [
                Figures.Run(text: "the device has four tracks", isFigure: false)
            ])
        #expect(Figures.split("").isEmpty)
    }

    /// A note letter is a figure's head only where a word does not run into it, so the digit alone
    /// is taken out of a word that happens to end in one.
    @Test func adigitInsideAWordIsNotGivenANoteLetter() {
        #expect(figures(in: "M6") == ["6"])
        #expect(figures(in: "mid2") == ["2"])
        #expect(figures(in: "ABC3") == ["3"])
        #expect(figures(in: "C3") == ["C3"])
    }

    /// A `.` or a `/` runs on only between digits; a sentence's full stop is prose.
    @Test func aseparatorEndsTheFigureWhereNoDigitFollows() {
        #expect(figures(in: "the pattern holds 192.") == ["192"])
        #expect(figures(in: "and/or 4") == ["4"])
    }
}
