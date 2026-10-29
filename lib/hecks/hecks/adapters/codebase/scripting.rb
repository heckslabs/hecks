# frozen_string_literal: true

require_relative "../../../tools/move_disables"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `ScriptRun` asks of the working tree: one named one-off script, planned, or
      # applied once confirmed. A script's body is a tool under `lib/hecks/tools`; `SCRIPTS` names
      # the ones this family may run, so a record cannot reach a tool it does not list.
      module Scripting
        # Every operation this family carries out.
        OPERATIONS = %w[plan_script apply_script].freeze

        # Each script a record may name, with the tool that carries it out.
        SCRIPTS = { "move_disables" => Hecks::Tools::MoveDisables }.freeze

        module_function

        # Carries out one operation on the named script.
        #
        # @param operation [String] one of `OPERATIONS`
        # @param held [Hash] the `ScriptRun` record's fields
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused: the tool runs in this process
        # @return [String] the tool's plan, or the plan and what it wrote
        # @raise [ConsoleCapture::Failure] when the record names no script this family runs
        def call(operation, held, tree, shell: nil)
          args = held.transform_values { |value| value.is_a?(Hash) ? value[:value] : value }
          name = args[:script].to_s
          tool = SCRIPTS.fetch(name) do
            raise ConsoleCapture::Failure, "no script named #{name.inspect}; the scripts are #{SCRIPTS.keys.join(", ")}"
          end
          tool.transform(root: tree.root, apply: operation == "apply_script")
        end
      end
    end
  end
end
