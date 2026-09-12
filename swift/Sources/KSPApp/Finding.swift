import KSPKit

struct Finding: Sendable, Equatable, Identifiable {
    let id: Int
    let text: String
    let severity: Severity
}

extension Report {
    func rows(verbose: Bool) -> [Finding] {
        let lines: [(text: String, severity: Severity)] =
            verbose
            ? entries.map { ($0.message, $0.severity) }
            : grouped().map { group in
                let severity: Severity =
                    group.entries.contains { $0.severity == .error } ? .error : .warning
                return (group.headline, severity)
            }
        return lines.enumerated()
            .sorted { one, other in
                one.element.severity == other.element.severity
                    ? one.offset < other.offset : one.element.severity == .error
            }
            .map { Finding(id: $0.offset, text: $0.element.text, severity: $0.element.severity) }
    }
}
