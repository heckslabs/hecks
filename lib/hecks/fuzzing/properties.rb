require "json"
require_relative "../bluebook/model_check"
require_relative "../bluebook/meta_validator"
require_relative "../ports/query/in_memory"
require_relative "../query_specification/field_path"
require_relative "../runtime/value"
require_relative "properties/lifecycle_and_replay"
require_relative "properties/querying"
require_relative "properties/guards"
require_relative "properties/dispatch_and_mutations"
require_relative "properties/invariants_and_aggregation"
require_relative "properties/corrections"
require_relative "properties/outbox"
require_relative "properties/policy_wiring"
require_relative "properties/references"
require_relative "properties/catalog"

module Hecks
  module Fuzzing
    # Declared properties, checked over a replayed history: each maps a name
    # to `->(history) { true, or a message string naming what broke }`.
    module Properties
      # Grouped by responsibility across properties/*.rb; `extend`ed so each
      # stays reachable as `Properties.foo(history)`, matching `module_function` below.
      extend LifecycleAndReplay
      extend Querying
      extend Guards
      extend DispatchAndMutations
      extend DryRuns
      extend InvariantsAndAggregation
      extend Corrections
      extend Outbox
      extend PolicyWiring
      extend References

      module_function

      # Runs the standard property battery over one replayed history — all but
      # determinism, which replays twice itself and so is checked separately.
      #
      # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
      # @return [Hash{Symbol => true, String}] each property name mapped to `true`
      #   (passed) or a message string naming what broke
      def check(history)
        PROPERTY_NAMES.to_h { |name| [name, public_send(name, history)] }
      end
    end
  end
end
