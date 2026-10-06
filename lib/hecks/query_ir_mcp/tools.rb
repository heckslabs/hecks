# frozen_string_literal: true

module Hecks
  module QueryIrMcp
    # The three tools, as an MCP client lists them.
    TOOLS = [
      {
        name:        "query_ir_constructs",
        description: "For a bluebook IR construct (Aggregate, Entity, Command, Query, ValueObject, Policy, " \
                     "ReadModel, ProcessManager, Bluebook) or all of them, the real structural diff between " \
                     "what the Ruby class emits and what the self-hosted meta-domain declares for it. Use " \
                     "this instead of reading entity.rb/entity.bluebook (or the equivalent pair for another " \
                     "construct) by hand to check whether a new IR field has been fully propagated.",
        inputSchema: {
          type:       "object",
          properties: {
            names: {
              type:        "array",
              items:       { type: "string" },
              description: "Construct names to check (e.g. [\"Entity\"]). Omit or leave empty for all constructs."
            }
          }
        }
      },
      {
        name:        "query_ir_duplicates",
        description: "Every given/ensures/invariant DECLARATION across the real corpus " \
                     "(banking/pizzas/compliance) and the self-hosted meta-domain, grouped by (kind, " \
                     "description, canonical predicate), reporting every group with more than one " \
                     "independently-declared rule (already-deduped references, which share the same " \
                     "underlying rule object, are excluded). Use this to find real corpus duplication " \
                     "before proposing a new 'declared once, referenced by name' resolution rule.",
        inputSchema: {
          type:       "object",
          properties: {
            domains:      {
              type:        "array",
              items:       { type: "string" },
              description: "Real example domain directories to scan (e.g. [\"examples/banking\"]). Omit for " \
                           "every real example domain."
            },
            include_meta: {
              type:        "boolean",
              description: "Include the self-hosted meta-domain (lib/hecks/language/bluebook). Defaults to true."
            }
          }
        }
      },
      {
        name:        "query_ir_impact",
        description: "For one construct/field pair, which of the six propagation touchpoints " \
                     ".claude/skills/bluebook-construct-creator/SKILL.md walks in prose already show signs " \
                     "of it, and which don't: the meta-domain grammar, docs/resolution-rules/, " \
                     "Assembly::Contracts, Reconstruction's hand-typed aggregate(row)/entity(row) (only " \
                     "applicable to Aggregate/Entity), the fuzzer's FEATURE_COVERAGE/" \
                     "GUARANTEED_BY_CONSTRUCTION, and the Rust mirror. Advisory, not a gate.",
        inputSchema: {
          type:       "object",
          properties: {
            name:  { type: "string", description: "Construct name (e.g. \"Aggregate\")." },
            field: { type: "string", description: "The field name to check (e.g. \"preconditions\")." }
          },
          required:   %w[name field]
        }
      }
    ].freeze
  end
end
