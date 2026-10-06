require_relative "../properties"

module Hecks
  module Doors
    module McpDoor
      module ToolDefinitions
        # The tools that read a domain: its events, state, shape and wiring.
        module Reading
          include Properties

          LIST = [
            {
              name:        "events",
              description: "What actually HAPPENED, with payloads, to one aggregate/record — events THIS DOOR witnessed " \
                           "(every real dispatch ever routed through it, sourced from its own audit log — not a full " \
                           "domain-wide event-sourcing replay). Distinct from `state` (what's stored now) and `history` " \
                           "(append-only operation snapshots, no payload). Narrow with `aggregate` and (requires " \
                           "`aggregate`) `id`; `limit` keeps only the most recent.",
              inputSchema: {
                type:       "object",
                properties: {
                  domain:    DOMAIN_PROPERTY,
                  aggregate: { type: "string", description: "Narrow to one aggregate, e.g. \"Account\"." },
                  id:        { type: "string", description: "Narrow to one record's own events. Requires `aggregate`." },
                  limit:     { type: "integer", description: "Keep only the most recent N events. Omit for all of them." }
                },
                required:   %w[domain]
              }
            },
            {
              name:        "state",
              description: "Read what an aggregate actually has stored, no verb involved. Pass `id` for one record; " \
                           "omit it to list every record the aggregate currently holds.",
              inputSchema: {
                type:       "object",
                properties: {
                  domain:    DOMAIN_PROPERTY,
                  aggregate: { type: "string", description: "The aggregate's name, e.g. \"Account\"." },
                  id:        { type: "string", description: "A specific record's id. Omit to list every record." },
                  summary:   SUMMARY_PROPERTY
                },
                required:   %w[domain aggregate summary]
              }
            },
            {
              name:        "catalog",
              description: "Zoom level one: every aggregate a domain declares, and every command/query name each " \
                           "answers to. No summary needed — this changes nothing and commits nothing to any log.",
              inputSchema: {
                type:       "object",
                properties: { domain: DOMAIN_PROPERTY },
                required:   %w[domain]
              }
            },
            {
              name:        "describe",
              description: "Zoom level two: one aggregate's full contract — every command's arguments, the states it " \
                           "may be issued from, and every way it can refuse. Omit `aggregate` for the whole domain.",
              inputSchema: {
                type:       "object",
                properties: {
                  domain:    DOMAIN_PROPERTY,
                  aggregate: { type: "string", description: "Narrow to one aggregate. Omit for the whole domain." }
                },
                required:   %w[domain]
              }
            },
            {
              name:        "validate",
              description: "Zoom level three: is this domain's wiring sound — every bind names a declared aggregate, " \
                           "every adapter satisfies its port, the default adapter is usable. {valid:false, error:…} " \
                           "on a real wiring defect, never a bare crash. Set `deep: true` to also model-check the IR " \
                           "for dead lifecycle transitions, unreachable saga states, and dispatches to nowhere.",
              inputSchema: {
                type:       "object",
                properties: {
                  domain: DOMAIN_PROPERTY,
                  deep:   { type: "boolean", description: "Also run the static model checker (lifecycle/saga/policy IR)." }
                },
                required:   %w[domain]
              }
            },
            {
              name:        "domains",
              description: "Zoom level zero: every domain directory found under a root (default \"examples\"), so a " \
                           "caller who doesn't already know a path can find one.",
              inputSchema: {
                type:       "object",
                properties: { under: { type: "string", description: "Root directory to scan. Defaults to \"examples\"." } }
              }
            }
          ].freeze
        end
      end
    end
  end
end
