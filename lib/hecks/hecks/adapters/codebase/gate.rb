# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `GateRun` asks of the working tree: running a stage's checks.
      #
      # It runs `Hecks::Tools::Gate` in this process. The tool starts the stage's checks together,
      # each as its own process, and answers 1 when any is red; the refusal is what the red checks
      # printed, so `--wait` and the journal both say which check failed.
      module Gate
        # Every operation this family carries out.
        OPERATIONS = %w[gate].freeze

        module_function

        # Runs the stage.
        #
        # @param _operation [String] `gate`
        # @param held [Hash] the `GateRun` record's fields: `stage`, and `only` when given
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused: the tool runs in this process
        # @return [String] which checks passed
        # @raise [ConsoleCapture::Failure] with what the red checks printed
        def call(_operation, held, tree, shell: nil)
          plain = ->(name) { held[name].is_a?(Hash) ? held[name][:value] : held[name] }
          only = plain.call(:only).to_s
          argv = [plain.call(:stage).to_s, *("only=#{only}" unless only.empty?)]
          RubyChild.new(tree).answer("gate", *argv).strip
        end
      end
    end
  end
end
