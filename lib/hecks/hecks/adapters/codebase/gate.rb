# frozen_string_literal: true

require_relative "tree"
require_relative "ruby_child"
require_relative "heavy_slots"

module Hecks
  module Adapters
    module Codebase
      # What Codebase's `GateRun` asks of the working tree: running a stage's checks.
      #
      # It runs `Hecks::Tools::Gate` in this process. The tool starts the stage's checks together,
      # each as its own process, and answers 1 when any is red; the refusal is what the red checks
      # printed, so `--wait` and the journal both say which check failed. A run takes a heavy-job
      # place first ({HeavySlots}), so the gates and spec batches of many sessions queue.
      module Gate
        # Every operation this family carries out.
        OPERATIONS = %w[gate].freeze

        # The gate's red verdict line: `[gate quick] red: shape_ledger, rubocop`.
        RED = /^\[gate (\S+)\] red: ([^;\n]+)/

        # What stands between the checks of a verdict line.
        CHECK_SEPARATOR = /\s*,\s*/

        # A red gate's refusal: what the red checks printed, and the cause they name. An ask's
        # refusal carries the error's `kind`, so a policy tells one failing cause from another
        # without reading the text.
        class Red < ConsoleCapture::Failure
          # @return [String] `gate-<stage>-<check>-<check>`, the red checks in name order
          attr_reader :kind

          # @param message [String] what the red checks printed
          # @param kind [String] the cause
          def initialize(message, kind)
            super(message)
            @kind = kind
          end
        end

        module_function

        # Runs the stage.
        #
        # @param _operation [String] `gate`
        # @param held [Hash] the `GateRun` record's fields: `stage`, and `only` when given
        # @param tree [Tree] the working tree, already known to be a hecks checkout
        # @param shell [#capture, nil] unused: the tool runs in this process
        # @return [String] which checks passed
        # @raise [Red] with what the red checks printed and the cause they name
        # @raise [ConsoleCapture::Failure] with what the run printed, when it names no red check
        def call(_operation, held, tree, shell: nil)
          plain = ->(name) { held[name].is_a?(Hash) ? held[name][:value] : held[name] }
          only = plain.call(:only).to_s
          argv = [plain.call(:stage).to_s, *("only=#{only}" unless only.empty?)]
          out = named_red { run(tree, argv) }
          { report: { value: out } }.merge(counts_of(out))
        end

        # Runs the block, naming the cause on the failure of a red gate.
        #
        # @yield the gate run
        # @return [String] what the block answers
        # @raise [Red] when the block fails with a report naming red checks
        def named_red
          yield
        rescue ConsoleCapture::Failure => e
          cause = cause_of(e.message)
          raise e unless cause

          raise Red.new(e.message, cause)
        end

        # The cause a gate's printed report names.
        #
        # @param report [String] what the gate printed
        # @return [String, nil] `gate-<stage>-<check>-<check>`, nil when no check is named red
        def cause_of(report)
          match = RED.match(report)
          checks = match ? check_names(match[2]) : []
          ["gate", match[1], *checks].join("-") if checks.any?
        end

        # @param list [String] the comma-separated checks of a red verdict line
        # @return [Array<String>] the check names, in name order
        def check_names(list) = list.strip.split(CHECK_SEPARATOR).sort

        # Runs the gate tool once a heavy-job place is free.
        #
        # @param tree [Tree] the checkout
        # @param argv [Array<String>] the stage and its `only=` filter
        # @return [String] what the gate printed, after the line naming any wait for a place
        def run(tree, argv) = HeavySlots.admitted(tree.root, "gate") { RubyChild.new(tree).answer("gate", *argv).strip }

        # The counts the gate tool prints for the verdict; a run that printed none claims zero.
        COUNTS_LINE = /^gate-counts expected=(\d+) recorded=(\d+)$/

        # @param out [String] the gate's standard output
        # @return [Hash] `expected:` and `recorded:`, each a value object's value
        def counts_of(out)
          match = COUNTS_LINE.match(out)
          expected, recorded = match ? match.captures : %w[0 0]
          { expected: { value: expected }, recorded: { value: recorded } }
        end
      end
    end
  end
end
