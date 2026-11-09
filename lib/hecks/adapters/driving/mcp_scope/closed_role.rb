module Hecks
  module Adapters
    module Driving
      class McpScope
        # A scope that serves no tool at all: the role has routing rows and none names a command of
        # the checkout, or its rows could not be read. That is not permission, so the server refuses
        # every call by name instead of serving the unrestricted set.
        module ClosedRole
          # The role whose server serves nothing, or nil for a scope that serves some.
          attr_reader :closed_role

          # @return [Boolean] whether this scope serves no tool
          def closed? = !@closed_role.nil?

          # @param name [String] the tool asked for
          # @return [Hash] the refusal, naming the role
          def closed_refusal(name)
            { ok:    false,
              error: "#{name.inspect} is refused: no commands for role #{@closed_role}; its routing rows " \
                     "name no command this checkout has, so this server serves no tool" }
          end

          # @return [Array<String>] the standing note for a closed scope
          def closed_notes = ["no commands for role #{@closed_role}: this server serves no tool"]
        end
      end
    end
  end
end
