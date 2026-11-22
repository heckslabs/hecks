# frozen_string_literal: true

require "hecks/adapters/driving/resident/client"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # The MCP stdio entry as a client of the control process: it asks the checkout's resident
        # to serve the session on this process's own stdin, stdout and stderr, and loads no domain.
        #
        # The session is a child of the resident for as long as the editor keeps it open. When the
        # resident retires (its code changed) or goes away, the child ends, the client says so
        # on stderr and ends with status 1, and the editor starts the server again, which then
        # finds a fresh resident or serves cold.
        module Thin
          # The launcher's path from a checkout's root.
          LAUNCHER = %w[exe hecks].freeze

          module_function

          # Hands the session to the control process when one answers; ends with its status.
          # Returns, with a word on stderr, when none answers, so the caller serves cold.
          #
          # @param argv [Array<String>] the arguments after the command, as `serve_stdio` got them
          # @param root [String] the checkout whose resident is asked
          # @return [void]
          def serve(argv, root: File.expand_path("../../../../..", __dir__))
            return if defined?(::Hecks::Adapters::Driving::Resident::CHILD)

            script = File.join(root, *LAUNCHER)
            status, = Resident::Client.ask(root, script, argv: ["mcp!", *argv])
            return exit(status) if status

            warn("hecks: control process down, running cold")
          rescue *Resident::Client::LOST
            warn("hecks: control process down, running cold")
          end
        end
      end
    end
  end
end
