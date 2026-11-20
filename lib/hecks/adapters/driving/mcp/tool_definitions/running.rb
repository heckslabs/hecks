require_relative "../../mcp/properties"

module Hecks
  module Adapters
    module Driving
      module Mcp
        module ToolDefinitions
          # The tool that runs a launcher command by the name `exe/hecks` takes. Only a commands
          # server serves it (`McpScope::LauncherDoor::COMMANDS_ONLY_TOOLS`).
          module Running
            include Properties

            LIST = [
              {
                name:        "run",
                description: "Run a command by the name the launcher takes, in any of its spellings " \
                             "(Work.revise!, SendTrain.board!, Hecks::SendTrain.Board, send_train.board!), an attached " \
                             "bluebook's command unprefixed. The line is resolved and refused exactly as `exe/hecks` " \
                             "resolves and refuses it. A command that declares `confirm` is refused: it runs only on " \
                             "the command line. Answers the launcher's exit status and its answer, parsed when it is " \
                             "JSON; `ok` is false whenever the launcher would exit non-zero.",
                inputSchema: {
                  type:       "object",
                  properties: {
                    domain:   DOMAIN_PROPERTY,
                    command:  { type: "string", description: "The command as the launcher names it, e.g. \"Work.revise!\"." },
                    args:     { type:        "object",
                                description: "The command's arguments; a nested object is a dotted path " \
                                             "({\"reason\":{\"value\":\"x\"}} is reason.value=x) and a list is one " \
                                             "space-separated value." },
                    summary:  SUMMARY_PROPERTY,
                    source:   SOURCE_PROPERTY,
                    role:     ROLE_PROPERTY,
                    actor_id: ACTOR_ID_PROPERTY,
                    wait:     { type: "boolean", description: "Answer once the run has settled, as --wait does. Default true." },
                    plan:     { type: "boolean", description: "Preview the run, as --plan does, and change nothing." }
                  },
                  required:   %w[domain command summary]
                }
              }
            ].freeze
          end
        end
      end
    end
  end
end
