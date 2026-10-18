# devin-kick

Devin (Cognition) as a side kick or a main kick, from Swift: one binary, `kick`, with a CLI and
an MCP stdio server (`kick serve`), both wrapping the same library, `DevinKickKit`, over Devin's
official v3 REST API.

- **Side kick:** a capable model orchestrates and delegates bounded jobs, single or in batches,
  and checks the results itself.
- **Main kick:** a smaller model hands Devin the whole task and only relays: delegate, check,
  answer, read the result.

Work in progress; see the milestones in the Roadmap once the first milestone lands.
