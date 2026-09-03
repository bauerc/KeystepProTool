import Foundation
import Testing

@testable import KSPKit

@Suite struct ReadCacheTests {
    static func stub(_ name: String) -> Project {
        Project(
            device: "KeyStepPro", version: nil, tempoBPM: 120, globalSwingPercent: 50,
            currentScene: 1, tracks: [], sourceName: name)
    }

    static func url(_ name: String) -> URL { URL(filePath: "/nowhere/\(name).KeyStepPro") }

    /// Counts what the cache let through, which is the only thing worth asserting about a cache.
    final class Parses: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func parse(_ url: URL) -> Project {
            let name = url.lastPathComponent
            lock.withLock { names.append(name) }
            return ReadCacheTests.stub(name)
        }

        var count: Int { lock.withLock { names.count } }
    }

    @Test func aSecondReadOfOnePathIsAHit() throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        let first = try cache.project(at: Self.url("a"), parse: parses.parse)
        let second = try cache.project(at: Self.url("a"), parse: parses.parse)

        #expect(parses.count == 1)
        #expect(first == second)
        #expect(cache.statistics.hits == 1)
        #expect(cache.statistics.misses == 1)
        #expect(cache.statistics.count == 1)
    }

    @Test func distinctPathsEachGetTheirOwnEntry() throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        let a = try cache.project(at: Self.url("a"), parse: parses.parse)
        let b = try cache.project(at: Self.url("b"), parse: parses.parse)

        #expect(parses.count == 2)
        #expect(a.sourceName == "a.KeyStepPro")
        #expect(b.sourceName == "b.KeyStepPro")
        #expect(cache.statistics.count == 2)
    }

    @Test func theEntryPastCapacityEvictsTheOldest() throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        for index in 0..<17 {
            _ = try cache.project(at: Self.url("\(index)"), parse: parses.parse)
        }
        #expect(cache.statistics.count == 16)

        _ = try cache.project(at: Self.url("0"), parse: parses.parse)
        #expect(parses.count == 18)

        _ = try cache.project(at: Self.url("16"), parse: parses.parse)
        #expect(parses.count == 18)
    }

    @Test func aHitMakesItsEntryTheMostRecentlyUsed() throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        for index in 0..<16 {
            _ = try cache.project(at: Self.url("\(index)"), parse: parses.parse)
        }
        _ = try cache.project(at: Self.url("0"), parse: parses.parse)
        _ = try cache.project(at: Self.url("16"), parse: parses.parse)

        // 0 was refreshed by the hit, so 1 is the oldest and the one that goes.
        _ = try cache.project(at: Self.url("0"), parse: parses.parse)
        #expect(parses.count == 17)

        _ = try cache.project(at: Self.url("1"), parse: parses.parse)
        #expect(parses.count == 18)
    }

    @Test func aFailedReadIsNotCached() throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        for _ in 0..<2 {
            #expect(throws: KSPError.self) {
                try cache.project(at: Self.url("a")) { _ in throw KSPError.value("no") }
            }
        }
        #expect(cache.statistics.count == 0)

        _ = try cache.project(at: Self.url("a"), parse: parses.parse)
        #expect(parses.count == 1)
    }

    @Test func clearingEmptiesTheEntriesAndTheCounters() throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        _ = try cache.project(at: Self.url("a"), parse: parses.parse)
        _ = try cache.project(at: Self.url("a"), parse: parses.parse)
        cache.clear()

        #expect(cache.statistics.count == 0)
        #expect(cache.statistics.hits == 0)
        #expect(cache.statistics.misses == 0)

        _ = try cache.project(at: Self.url("a"), parse: parses.parse)
        #expect(parses.count == 2)
    }

    @Test func concurrentReadsOfOnePathAllGetTheSameProject() async throws {
        let cache = ReadCache(capacity: 16)
        let parses = Parses()
        let target = Self.url("a")

        let projects = await withTaskGroup(of: Project?.self) { group in
            for _ in 0..<32 {
                group.addTask { try? cache.project(at: target, parse: parses.parse) }
            }
            return await group.reduce(into: [Project]()) { found, next in
                if let next { found.append(next) }
            }
        }

        #expect(projects.count == 32)
        #expect(Set(projects).count == 1)
    }

    @Test func readerServesTheSecondLoadOfOnePathFromTheCache() throws {
        Reader.cacheClear()
        let url = RepoData.projectFiles.appending(path: "project_5.KeyStepPro")
        let first = try Reader.load(contentsOf: url)
        let second = try Reader.load(contentsOf: url)

        #expect(first == second)
        #expect(Reader.cacheInfo.hits >= 1)
        #expect(Reader.cacheInfo.capacity == 16)
    }
}
