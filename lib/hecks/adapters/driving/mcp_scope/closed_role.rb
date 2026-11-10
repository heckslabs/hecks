module Hecks
  module Adapters
    module Driving
      class McpScope
        # A scope that serves no tool at all: the role has routing rows and none names a command of
        # the checkout, or its rows could not be read. That is not permission, so the server refuses
        # every call by name instead of serving the unrestricted set. A scope whose rows could not
        # be read says why ({#unreadable}), so a broken agents bluebook never reads as a role with
        # no commands.
        module ClosedRole
          # The role whose server serves nothing, or nil for a scope that serves some.
          attr_reader :closed_role

          # Why the role's rows could not be read, or nil when they were read.
          attr_reader :unreadable_reason

          # @param reason [String] the error that stopped the rows being read
          # @return [self] this scope, closed because its rows could not be read
          def unreadable(reason)
            @unreadable_reason = reason
            self
          end

          # @return [Boolean] whether this scope serves no tool
          def closed? = !@closed_role.nil?

          # @param name [String] the tool asked for
          # @return [Hash] the refusal, naming the role
          def closed_refusal(name) = { ok: false, error: "#{name.inspect} is refused: #{closed_why}" }

          # @return [Array<String>] the standing note for a closed scope
          def closed_notes = ["#{closed_why}: this server serves no tool"]

          private

          def closed_why
            return "role #{@closed_role}: its routing rows could not be read (#{@unreadable_reason})" if @unreadable_reason

            "no commands for role #{@closed_role}; its routing rows name no command this checkout has"
          end
        end
      end
    end
  end
end
