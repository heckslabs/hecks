require_relative "../../mcp/properties"

module Hecks
  module Adapters
    module Driving
      module Mcp
        module ToolDefinitions
          # The tools that issue a command or ask a question.
          module Calling
            include Properties

            LIST = [
              {
                name:        "dispatch",
                description: "Issue a command against a booted domain — or, with `steps`, several in one call. `command` is " \
                             "the short or qualified verb name (the catalog/describe tools show what's available). Set " \
                             "`dry_run: true` to check whether it WOULD succeed without committing anything. Answers the " \
                             "record's id, its resulting state, and the events it announced — or a structured refusal, " \
                             "never a crash.",
                inputSchema: {
                  type:       "object",
                  properties: {
                    domain:   DOMAIN_PROPERTY,
                    command:  { type: "string", description: "The command's short or qualified name, e.g. \"open_account\". " \
                                                             "Ignored when `steps` is given." },
                    args:     ARGS_PROPERTY,
                    summary:  SUMMARY_PROPERTY,
                    source:   SOURCE_PROPERTY,
                    role:     ROLE_PROPERTY,
                    actor_id: ACTOR_ID_PROPERTY,
                    dry_run:  { type: "boolean", description: "Preview only — check the command would succeed, commit nothing. " \
                                                              "Ignored when `steps` is given." },
                    steps:    {
                      type:        "array",
                      description: "Run several commands in one call, in order. Each item: {command, args}. When given, " \
                                   "`command`/`args`/`dry_run` above are ignored.",
                      items:       {
                        type:       "object",
                        properties: { command: { type: "string" }, args: ARGS_PROPERTY },
                        required:   %w[command]
                      }
                    }
                  },
                  required:   %w[domain summary]
                }
              },
              {
                name:        "query",
                description: "Ask a declared question of a booted domain. `question` is the short or qualified query name. " \
                             "Answers the row array the query itself declares.",
                inputSchema: {
                  type:       "object",
                  properties: {
                    domain:   DOMAIN_PROPERTY,
                    question: { type: "string", description: "The query's short or qualified name." },
                    args:     ARGS_PROPERTY,
                    summary:  SUMMARY_PROPERTY,
                    source:   SOURCE_PROPERTY,
                    role:     ROLE_PROPERTY,
                    actor_id: ACTOR_ID_PROPERTY
                  },
                  required:   %w[domain question summary]
                }
              }
            ].freeze
          end
        end
      end
    end
  end
end
