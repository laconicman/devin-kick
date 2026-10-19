/// The side profile (plan decision 3): eight tools for a capable model that delegates bounded
/// jobs to Devin, single or in batches, and checks the results itself.
///
/// A profile is an array, chosen once from `kick serve --profile`, never a branch inside a
/// handler (amendment A17). M3's main profile is another array, and the two never share a name,
/// so mounting both by mistake can't collide (Design: "A name distinct from the service").
enum SideProfile {
    /// The tools, in the order a model uses them; the operator's launch options are baked in.
    static func tools(_ options: ServeOptions) -> [ToolSpec] {
        [
            .upload, .start(bypassApproval: options.bypassApproval), .status, .wait(maximum: options.maxWait),
            .save, .messages, .reply, .archive,
        ]
    }
}
