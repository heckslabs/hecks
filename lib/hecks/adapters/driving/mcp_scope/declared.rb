module Hecks
  module Adapters
    module Driving
      class McpScope
        # The lists a restricted server is held to, read from Governance's `Door` aggregate the
        # first time one is named, so no copy lives in Ruby:
        # `READER_TOOLS` (each reads a domain or the server's own audit log and writes no domain
        # state), `COMMAND_TOOLS` (those, and `dispatch` for the allowed commands),
        # `DENIED_ARGUMENTS` (names a restricted server never passes on, whatever command carries
        # them), `PATH_ARGUMENTS` (values that must resolve, symlinks followed, inside
        # `Storehouse::BOOT_ROOT` and hold no colon) and `REF_ARGUMENTS` (values that must be plain
        # git refs, so one cannot read as an option to git).
        module Declared
          VALUE_OBJECTS = {
            READER_TOOLS: "ReaderTool", DENIED_ARGUMENTS: "DeniedArgument",
            PATH_ARGUMENTS: "PathArgument", REF_ARGUMENTS: "RefArgument"
          }.freeze

          module_function

          # @param name [Symbol] the constant looked up on `McpScope`
          # @return [Array<String>, nil] the declared list, or nil when `name` is not one of them
          def list(name)
            return (list(:READER_TOOLS) + of("DispatchTool")).freeze if name == :COMMAND_TOOLS

            of(VALUE_OBJECTS.fetch(name)) if VALUE_OBJECTS.key?(name)
          end

          # @param value_object [String] a closed-set value object of the `Door` aggregate
          # @return [Array<String>] its members
          def of(value_object)
            Framework.closed_set("Governance", "Door", value_object)
          end
        end
      end
    end
  end
end
