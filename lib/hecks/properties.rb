require "json"
require_relative "bluebook/model_check"
require_relative "bluebook/meta_validator"
require_relative "ports/query/in_memory"
require_relative "query_specification/field_path"
require_relative "runtime/value"
require_relative "properties/parts/lifecycle_and_replay"
require_relative "properties/parts/bulk_parity"
require_relative "properties/parts/set_transform_parity"
require_relative "properties/parts/querying"
require_relative "properties/parts/guards"
require_relative "properties/parts/dispatch_and_mutations"
require_relative "properties/parts/invariants_and_aggregation"
require_relative "properties/parts/corrections"
require_relative "properties/parts/outbox"
require_relative "properties/parts/policy_wiring"
require_relative "properties/parts/references"
require_relative "properties/parts/refusals"
require_relative "properties/parts/role_checks"
require_relative "properties/parts/read_model_names"
require_relative "properties/parts/read_models"
require_relative "properties/parts/catalog"
require_relative "properties/parts/guaranteed_by_construction"

module Hecks
  module Fuzzing
    # Declared properties, checked over a replayed history: each maps a name
    # to `->(history) { true, or a message string naming what broke }`.
    module Properties
      # Grouped by responsibility across properties/*.rb; `extend`ed so each
      # stays reachable as `Properties.foo(history)`, matching `module_function` below.
      extend LifecycleAndReplay
      extend BulkParity
      extend SetTransformParity
      extend Querying
      extend Guards
      extend DispatchAndMutations
      extend DryRuns
      extend InvariantsAndAggregation
      extend Corrections
      extend Outbox
      extend PolicyWiring
      extend References
      extend Refusals
      extend RoleChecks
      extend ReadModelNames
      extend ReadModels

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
