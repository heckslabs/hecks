require_relative "../properties"

module Hecks
  module Doors
    module McpDoor
      module ToolDefinitions
        # The tools that read what has been recorded: write history, behaviors and the audit log.
        module Auditing
          include Properties

          LIST = [
            {
              name:        "history",
              description: "The full write history for every aggregate in a domain — every operation an append-only " \
                           "adapter ever recorded, not just current state. An aggregate on a non-append-only adapter " \
                           "answers an empty history honestly.",
              inputSchema: {
                type:       "object",
                properties: { domain: DOMAIN_PROPERTY },
                required:   %w[domain]
              }
            },
            {
              name:        "behaviors",
              description: "Run a domain's hand-curated `.behaviors` example tests and report pass/fail/error per test. " \
                           "`target` is a single `.behaviors` file or a directory to sweep.",
              inputSchema: {
                type:       "object",
                properties: { target: { type: "string", description: "A .behaviors file, or a directory to sweep." } },
                required:   %w[target]
              }
            },
            {
              name:        "follow",
              description: "Tail this door's own audit log for a domain — the last `limit` dispatch/query/state/dry-run " \
                           "calls made through it, each carrying its summary, source, and outcome.",
              inputSchema: {
                type:       "object",
                properties: {
                  domain: DOMAIN_PROPERTY,
                  limit:  { type: "integer", description: "How many recent entries to return. Defaults to 20." }
                },
                required:   %w[domain]
              }
            }
          ].freeze
        end
      end
    end
  end
end
