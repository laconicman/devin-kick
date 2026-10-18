import Foundation
import Testing

/// Gives each test one parent for its temporary directories and removes it when the test ends,
/// so a run leaves nothing behind in `$TMPDIR`; before this, every `swift test` left about twenty
/// stores and sandboxes. A test scoping trait (Swift Testing, `TestScoping`); every suite applies
/// it, and `temporaryDirectory()` reads the parent through a task-local.
struct TemporaryDirectories: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    @TaskLocal static var parent: URL?

    // `@concurrent`, as for every conformance to a dependency's protocol under
    // NonisolatedNonsendingByDefault (Design: "Explicit `@concurrent` at module boundaries").
    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appending(path: "devin-kick-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await Self.$parent.withValue(parent) { try await function() }
    }
}

extension SuiteTrait where Self == TemporaryDirectories {
    /// Each test's temporary directories, removed when it ends.
    static var temporaryDirectories: Self { Self() }
}

/// A fresh directory path (not created) under the running test's parent.
func temporaryDirectory() -> URL {
    let parent = TemporaryDirectories.parent
        ?? FileManager.default.temporaryDirectory.appending(path: "devin-kick-tests", directoryHint: .isDirectory)
    return parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}
