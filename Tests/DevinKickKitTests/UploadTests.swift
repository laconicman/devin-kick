@testable import DevinKickKit
import Foundation
import Testing

@Suite("Uploads — only from KICK_UPLOAD_ROOTS, never the same content twice", .temporaryDirectories)
struct UploadTests {
    static let uploaded = #"{"attachment_id":"00000000-0000-0000-0000-000000000001","name":"notes.txt","url":"https://app.devin.ai/attachments/00000000-0000-0000-0000-000000000001/notes.txt"}"#

    /// A root with `notes.txt` in it, and a sibling directory outside the root.
    struct Sandbox {
        let base = temporaryDirectory()
        var root: URL { base.appending(path: "root", directoryHint: .isDirectory) }
        var outside: URL { base.appending(path: "outside", directoryHint: .isDirectory) }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: root.appending(path: "notes.txt"))
            try Data("secret".utf8).write(to: outside.appending(path: "secret.txt"))
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func unsetRootsMeanNoUploadsAtAll() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        await #expect {
            try await DevinKick.scripted(transport).upload([sandbox.root.appending(path: "notes.txt").path])
        } throws: { error in
            (error as? KickError)?.exitCode == 78 && (error as? KickError)?.localizedDescription.contains("KICK_UPLOAD_ROOTS") == true
        }
        #expect(await transport.count("upload_attachment") == 0)
    }

    /// `..`, a symlink out of the root, and a plain outside path all resolve outside it.
    @Test(arguments: ["../outside/secret.txt", "link-out.txt", "OUTSIDE"])
    func escapesFromTheRootAreUsageErrors(_ path: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try FileManager.default.createSymbolicLink(
            at: sandbox.root.appending(path: "link-out.txt"), withDestinationURL: sandbox.outside.appending(path: "secret.txt")
        )
        let target = path == "OUTSIDE" ? sandbox.outside.appending(path: "secret.txt").path : path
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        let kick = try DevinKick.scripted(transport, environment: ["KICK_UPLOAD_ROOTS": sandbox.root.path])
        await #expect {
            try await kick.upload([target], relativeTo: sandbox.root)
        } throws: { error in
            (error as? KickError)?.exitCode == 64
        }
        #expect(await transport.count("upload_attachment") == 0)
    }

    @Test func theSecondUploadOfAFileIsACacheHit() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        // A root reached through a symlink still contains its files once both are resolved.
        let alias = sandbox.base.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sandbox.root)
        let kick = try DevinKick.scripted(transport, environment: ["KICK_UPLOAD_ROOTS": "/nonexistent:\(alias.path)"])

        let first = try await kick.upload(["notes.txt"], relativeTo: sandbox.root)
        #expect(first.map(\.cached) == [false])
        #expect(first.first?.url.hasSuffix("/notes.txt") == true)
        let second = try await kick.upload([sandbox.root.appending(path: "notes.txt").path])
        #expect(second.map(\.cached) == [true])
        #expect(second.first?.url == first.first?.url)
        #expect(await transport.count("upload_attachment") == 1)

        // The multipart body carries the file's name and its bytes.
        let body = try #require(await transport.bodies("upload_attachment").first)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains(#"filename="notes.txt""#))
        #expect(text.contains("hello"))
    }

    /// Two parallel uploads of one file make one upload: the second awaits the first's URL. A
    /// lookup → upload → record spans a suspension, which a long-lived server would otherwise race.
    @Test func parallelUploadsOfOneFileUploadItOnce() async throws {
        let sandbox = try Sandbox()
        let transport = ScriptedTransport(["upload_attachment": [.delayed(.milliseconds(200), .json(Self.uploaded))]])
        let kick = try DevinKick.scripted(transport, environment: ["KICK_UPLOAD_ROOTS": sandbox.root.path])
        async let first = kick.upload(["notes.txt"], relativeTo: sandbox.root)
        async let second = kick.upload(["notes.txt"], relativeTo: sandbox.root)
        let uploads = try await first + second
        #expect(await transport.count("upload_attachment") == 1)
        #expect(Set(uploads.map(\.url)).count == 1)
        #expect(uploads.count(where: \.cached) == 1)
    }

    /// An upload another process recorded after this one's first lookup is a cache hit.
    @Test func anotherProcesssUploadIsACacheHit() async throws {
        let sandbox = try Sandbox()
        try Data("other".utf8).write(to: sandbox.root.appending(path: "other.txt"))
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        let environment = ["KICK_UPLOAD_ROOTS": sandbox.root.path, "KICK_STORE": sandbox.base.appending(path: "store").path]
        let first = try DevinKick.scripted(transport, environment: environment)
        let second = try DevinKick.scripted(transport, environment: environment)
        #expect(try await first.upload(["other.txt"], relativeTo: sandbox.root).map(\.cached) == [false])
        #expect(try await second.upload(["notes.txt"], relativeTo: sandbox.root).map(\.cached) == [false])
        #expect(try await first.upload(["notes.txt"], relativeTo: sandbox.root).map(\.cached) == [true])
        #expect(await transport.count("upload_attachment") == 2)
    }

    /// Every path in a manifest resolves alike: `~` first, then relative to its directory
    /// (from the 2026-10-18 diff review through kick: `attach` didn't expand `~`).
    @Test func tildeExpandsBeforeTheManifestDirectoryApplies() throws {
        let base = URL(fileURLWithPath: "/tmp/manifest-dir", isDirectory: true)
        #expect(DevinKick.resolve("~/a.pdf", relativeTo: base).path == NSHomeDirectory() + "/a.pdf")
        #expect(DevinKick.resolve("files/a.pdf", relativeTo: base).path == "/tmp/manifest-dir/files/a.pdf")
        let roots = try UploadRoots([NSHomeDirectory()])
        #expect {
            try roots.resolve("~/devin-kick-no-such-file-\(UUID().uuidString)", relativeTo: base)
        } throws: { error in
            (error as? KickError)?.localizedDescription.hasPrefix("No such file") == true
        }
    }

    /// A file that becomes a symlink after it was checked is checked again as it is read, and
    /// nothing is uploaded (PR #11 review, r4308715320).
    @Test func aFileSwappedForASymlinkAfterTheCheckIsNotUploaded() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        let kick = try DevinKick.scripted(transport, environment: ["KICK_UPLOAD_ROOTS": sandbox.root.path])
        let checked = try #require(try kick.checkUploadable(["notes.txt"], relativeTo: sandbox.root).first)
        try FileManager.default.removeItem(at: checked)
        try FileManager.default.createSymbolicLink(at: checked, withDestinationURL: sandbox.outside.appending(path: "secret.txt"))
        await #expect {
            try await kick.upload(resolved: checked)
        } throws: { error in
            (error as? KickError)?.exitCode == 64
        }
        #expect(await transport.count("upload_attachment") == 0)
    }

    /// The cache is the organization's and the server's: the same file under another
    /// `DEVIN_ORG_ID` over one store is uploaded again (PR #11 review, r4308715119).
    @Test func anotherOrganizationDoesNotGetTheCachedURL() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let store = sandbox.base.appending(path: "store").path
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        let environment = ["KICK_UPLOAD_ROOTS": sandbox.root.path, "KICK_STORE": store]
        let first = try DevinKick.scripted(transport, environment: environment.merging(["DEVIN_ORG_ID": "org-a"]) { $1 })
        #expect(try await first.upload(["notes.txt"], relativeTo: sandbox.root).map(\.cached) == [false])
        #expect(try await first.upload(["notes.txt"], relativeTo: sandbox.root).map(\.cached) == [true])
        let second = try DevinKick.scripted(transport, environment: environment.merging(["DEVIN_ORG_ID": "org-b"]) { $1 })
        #expect(try await second.upload(["notes.txt"], relativeTo: sandbox.root).map(\.cached) == [false])
        #expect(await transport.count("upload_attachment") == 2)
    }

    /// A parent directory swapped for a symlink after the check is caught by the opened file's
    /// own path (PR #11 review, r4308715320, as edited).
    @Test func aParentSwappedForASymlinkAfterTheCheckIsNotUploaded() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let sub = sandbox.root.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: sub.appending(path: "notes.txt"))
        try Data("outside".utf8).write(to: sandbox.outside.appending(path: "notes.txt"))
        let transport = ScriptedTransport(["upload_attachment": [.json(Self.uploaded)]])
        let kick = try DevinKick.scripted(transport, environment: ["KICK_UPLOAD_ROOTS": sandbox.root.path])
        let checked = try #require(try kick.checkUploadable(["sub/notes.txt"], relativeTo: sandbox.root).first)
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: sandbox.outside)
        // The read itself refuses, as if the swap had landed after every path check: the opened
        // descriptor's own path is outside the root.
        let roots = try UploadRoots([sandbox.root.path])
        #expect { try DevinKick.readOpened(checked, within: roots) } throws: { ($0 as? KickError)?.exitCode == 64 }
        await #expect {
            try await kick.upload(resolved: checked)
        } throws: { error in
            (error as? KickError)?.exitCode == 64
        }
        #expect(await transport.count("upload_attachment") == 0)
        // Unswapped, the same read succeeds.
        try FileManager.default.removeItem(at: sub)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: sub.appending(path: "notes.txt"))
        #expect(try DevinKick.readOpened(checked, within: roots) == Data("inside".utf8))
    }

    @Test func aDirectoryIsNotAFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let kick = try DevinKick.scripted(ScriptedTransport([:]), environment: ["KICK_UPLOAD_ROOTS": sandbox.base.path])
        await #expect(throws: KickError.self) { try await kick.upload([sandbox.root.path]) }
    }
}
