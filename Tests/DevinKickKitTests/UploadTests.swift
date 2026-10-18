@testable import DevinKickKit
import Foundation
import Testing

@Suite("Uploads — only from KICK_UPLOAD_ROOTS, never the same content twice")
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

    @Test func aDirectoryIsNotAFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let kick = try DevinKick.scripted(ScriptedTransport([:]), environment: ["KICK_UPLOAD_ROOTS": sandbox.base.path])
        await #expect(throws: KickError.self) { try await kick.upload([sandbox.root.path]) }
    }
}
