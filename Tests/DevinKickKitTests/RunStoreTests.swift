@testable import DevinKickKit
import Foundation
import Synchronization
import Testing

/// Warnings a store emitted, for assertions.
final class WarningLog: Sendable {
    private let messages = Mutex<[String]>([])

    var all: [String] { messages.withLock { $0 } }

    var sink: RunStore.Warn {
        { [self] message in messages.withLock { $0.append(message) } }
    }
}

@Suite("RunStore — runs recorded at submit; the index throws, derived files warn", .temporaryDirectories)
struct RunStoreTests {
    static func run(_ runID: String = RunStore.mintRunID(), in directory: URL) -> RunState {
        RunState(runID: runID, directory: directory, mode: "swe-2-max", title: "A title", tags: ["kick", RunStore.runTag(runID)], resumable: true)
    }

    @Test func eventsFoldIntoARunAndSurviveAReopen() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let runID = RunStore.mintRunID()
        let directory = try await store.makeRunDirectory(runID: runID, title: "A title")
        var run = Self.run(runID, in: directory)
        try await store.append(IndexEvent(.requested, run: run))
        #expect(await store.lookup(runID)?.isOrphan == true)
        run.sessionID = "00000000000000000000000000000001"
        try await store.append(IndexEvent(.created, run: run))
        try await store.append(IndexEvent(.replied, run: run))
        var settled = IndexEvent(.settled, run: run)
        settled.settlement = "done"
        try await store.append(settled)

        // A second store reads the same index from disk.
        let reopened = try #require(await RunStore(root: root).lookup("00000000000000000000000000000001"))
        #expect(reopened.runID == runID)
        #expect(!reopened.isOrphan)
        #expect(reopened.replied)
        #expect(reopened.lastSettlement == "done")
        #expect(reopened.tags == ["kick", "kick-run-\(runID)"])
        #expect(await RunStore(root: root).lookup(directory.path)?.runID == runID)
        // The same directory named through a symlink.
        let alias = root.deletingLastPathComponent().appending(path: "alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let aliased = alias.appending(path: directory.path.replacingOccurrences(of: root.path + "/", with: "")).path
        #expect(await RunStore(root: root).lookup(aliased)?.runID == runID)
        #expect(await RunStore(root: root).runs(tagged: "kick-run-\(runID)").count == 1)
        #expect(await RunStore(root: root).runs(tagged: "other").isEmpty)
    }

    @Test func theStoreAndItsRunDirectoriesAreOwnerOnly() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await RunStore(root: root).makeRunDirectory(runID: RunStore.mintRunID(), title: nil)
        for url in [root, root.appending(path: "runs"), directory] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(permissions == 0o700, "\(url.path)")
        }
    }

    /// The index must not fail quietly: an unrecorded run can be lost.
    @Test func aFailedIndexWriteThrowsAStoreError() async throws {
        let blocker = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("not a directory".utf8).write(to: blocker)
        let store = RunStore(root: blocker)
        await #expect {
            try await store.append(IndexEvent(.requested, run: Self.run(in: blocker)))
        } throws: { error in
            (error as? KickError)?.exitCode == 73
        }
        await #expect(throws: KickError.self) {
            try await store.writeRequest(Data("{}".utf8), in: blocker.appending(path: "run"))
        }
    }

    @Test func aFailedDerivedWriteOnlyWarns() async throws {
        let blocker = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("not a directory".utf8).write(to: blocker)
        let warnings = WarningLog()
        let written = await RunStore(root: blocker, warn: warnings.sink)
            .writeDerived(Data("{}".utf8), to: blocker.appending(path: "session.json"))
        #expect(!written)
        #expect(warnings.all.count == 1)
        #expect(warnings.all.first?.contains("kick save") == true)
    }

    @Test func anUnreadableIndexLineIsSkippedWithAWarning() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let run = Self.run(in: root)
        try await store.append(IndexEvent(.requested, run: run))
        let handle = try FileHandle(forWritingTo: root.appending(path: "index.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"truncated\n".utf8))
        try handle.close()
        let warnings = WarningLog()
        #expect(await RunStore(root: root, warn: warnings.sink).runs().count == 1)
        #expect(warnings.all.count == 1)
    }

    /// Two stores (as two `kick` processes would) append to one index: every line stays whole.
    @Test func concurrentAppendsKeepEveryLineWhole() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = [RunStore(root: root), RunStore(root: root)]
        let longTitle = String(repeating: "a long title ", count: 60)
        try await withThrowingTaskGroup { group in
            for (number, store) in stores.enumerated() {
                group.addTask {
                    for index in 0..<100 {
                        var run = Self.run("test-\(number)-\(index)", in: root.appending(path: String(repeating: "deep/", count: 20)))
                        run.title = longTitle
                        try await store.append(IndexEvent(.requested, run: run))
                    }
                }
            }
            try await group.waitForAll()
        }
        let warnings = WarningLog()
        #expect(await RunStore(root: root, warn: warnings.sink).runs().count == 200)
        #expect(warnings.all.isEmpty)
    }

    /// 300 ids within one fixed second: past the birthday bound of 65,536 suffixes, so a draw
    /// collides with an id the index holds (p ≈ 0.5); every id handed out must still be new.
    @Test func aNewRunIDIsNeverOneTheIndexHolds() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let date = Date(timeIntervalSince1970: 1_791_900_000)
        var taken = Set<String>()
        for _ in 0..<300 {
            let runID = await store.newRunID(at: date)
            #expect(!taken.contains(runID))
            taken.insert(runID)
            try await store.append(IndexEvent(.requested, run: Self.run(runID, in: root)))
        }
    }

    @Test func runIDsAndSlugsHaveTheirShape() {
        #expect(RunStore.mintRunID().wholeMatch(of: /\d{8}-\d{6}-[0-9a-f]{4}/) != nil)
        #expect(RunStore.slug("[review] devin-kick M1 plan, 2026-10-18!") == "review-devin-kick-m1-plan-2026-10-18")
        #expect(RunStore.slug("Обзор: план") == "обзор-план")
        #expect(RunStore.slug(nil) == "run")
        #expect(RunStore.slug(String(repeating: "x", count: 99)).count == RunStore.maximumSlugLength)
    }
}
