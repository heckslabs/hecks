module Hecks
  module Adapters
    module Driving
      module Mcp
        # How the server learns what it may do: the `HECKS_SERVER_*` settings it was spawned with,
        # read once ({McpScope.start!}), so a bad setting refuses to start the server before
        # anything is written to stdout.
        module Scoping
          # @return [McpScope] this server's scope
          def scope
            @scope ||= McpScope.start!(server: Mcp::SERVER)
          end

          # @return [Array<String>] the standing notes, then what this server's scope says about
          #   `domain:`
          def warning_notes
            NOTES[0, 2] + (scope.restricted? ? scope.notes : [NOTES[2]])
          end
        end
      end
    end
  end
end
