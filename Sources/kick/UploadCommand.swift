import ArgumentParser
import DevinKickKit
import Foundation

/// `kick upload FILE…` — upload within `KICK_UPLOAD_ROOTS`, reusing earlier uploads.
struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload files for sessions; prints each file's attachment URL.",
        discussion: """
        Uploads are permanent, so only files inside KICK_UPLOAD_ROOTS (colon-separated \
        directories, symlinks resolved) are uploaded; with it unset, nothing is. A file whose \
        content and name were uploaded before is not sent again: its URL comes from the cache \
        in KICK_STORE.
        """
    )

    @Argument(help: "The files to upload.")
    var files: [String]

    func validate() throws {
        guard !files.isEmpty else { throw ValidationError("Name at least one file.") }
    }

    func run() async throws {
        try await reportingKickErrors { () async throws(KickError) in
            for upload in try await DevinKick.fromEnvironment().upload(files) {
                print("\(upload.file.path) → \(upload.url) (\(upload.cached ? "cached" : "uploaded"))")
            }
        }
    }
}
