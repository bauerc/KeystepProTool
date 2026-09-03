import Foundation

/// Decoded projects, most recently used last, so the four reads one drop makes cost one parse.
public final class ReadCache: @unchecked Sendable {
    public struct Statistics: Sendable, Hashable {
        public let hits: Int
        public let misses: Int
        public let count: Int
        public let capacity: Int
    }

    public let capacity: Int

    private let lock = NSLock()
    private var entries: [URL: Project] = [:]
    private var order: [URL] = []
    private var hits = 0
    private var misses = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    public var statistics: Statistics {
        lock.withLock {
            Statistics(hits: hits, misses: misses, count: entries.count, capacity: capacity)
        }
    }

    public func clear() {
        lock.withLock {
            entries.removeAll()
            order.removeAll()
            hits = 0
            misses = 0
        }
    }

    /// `parse` runs outside the lock, so a cold read of one file does not queue behind another's.
    /// Two callers racing the same path both parse, as they both do today; every read after hits.
    func project(at url: URL, parse: (URL) throws -> Project) throws -> Project {
        if let cached = lock.withLock({ recall(url) }) { return cached }
        let project = try parse(url)
        lock.withLock { store(project, for: url) }
        return project
    }

    private func recall(_ url: URL) -> Project? {
        guard let cached = entries[url] else {
            misses += 1
            return nil
        }
        hits += 1
        touch(url)
        return cached
    }

    private func store(_ project: Project, for url: URL) {
        entries[url] = project
        touch(url)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    private func touch(_ url: URL) {
        order.removeAll { $0 == url }
        order.append(url)
    }
}
