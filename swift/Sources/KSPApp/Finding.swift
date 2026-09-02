import KSPKit

/// One line of a ``Report`` as the window shows it: the report's own words, kept with the severity
/// that produced them so the row can be marked and ordered.
struct Finding: Sendable, Equatable, Identifiable {
    /// The line's place in the report, which is what holds equal severities in the report's order.
    let id: Int
    let text: String
    let severity: Severity
}

extension Report {
    /// ``render(verbose:)`` branch for branch, each line paired with its severity and errors raised
    /// above warnings. Display only: both CLIs still print the report's own order.
    func rows(verbose: Bool) -> [Finding] {
        // Not `Group.severity`, which is the first entry's: a kind raised as an error anywhere in
        // the group is an error on the one row that stands for the whole of it.
        let lines: [(text: String, severity: Severity)] =
            verbose
            ? entries.map { ($0.message, $0.severity) }
            : grouped().map { group in
                let severity: Severity =
                    group.entries.contains { $0.severity == .error } ? .error : .warning
                return (group.headline, severity)
            }
        // `sorted` promises no stability, and the order inside a severity is the report's own.
        return lines.enumerated()
            .sorted { one, other in
                one.element.severity == other.element.severity
                    ? one.offset < other.offset : one.element.severity == .error
            }
            .map { Finding(id: $0.offset, text: $0.element.text, severity: $0.element.severity) }
    }
}
