require_relative "../plugin"
require_relative "era/era_check"
require_relative "era/era_guard"
require_relative "era/era_tamper"
require_relative "era/storage_shape"
require_relative "era/lineage"
require_relative "era/postgres_era"
require_relative "era/translation"

module Hecks
  module Ports
    module Persistence
      module Plugins
        # ADR 0033 — requiring this file installs the plugin; nothing in Hecks core
        # requires it, so it loads only for a domain that binds `PostgresEra` (or asks explicitly).
        module Era
          module_function

          # Registers this plugin's era gates on one boot's gate list.
          #
          # Two `:pre_verify` gates: `era_compute_rules` always runs; `era_check` (ADR 0031)
          # runs only when the registry binds something lineage-capable.
          #
          # @param registry [Runtime::Registry] the registry being booted, asked whether any
          #   bluebook's first aggregate is bound to a lineage-capable adapter
          # @param gates [Runtime::BootGates] this boot's gate list, registered onto in place
          # @return [Runtime::BootGates, nil] `gates` when `:era_check` was registered; nil when
          #   the registry binds nothing lineage-capable, so only `:era_compute_rules` was added
          # @raise [Runtime::WiringError] if an aggregate's persistence binding is missing,
          #   ambiguous, or carries an unsupported role
          def contribute_boot_gates(registry, gates)
            gates.register(:era_compute_rules, lambda { |reg, _dir|
              Runtime::EraCheck.check_compute_rules_for_registry!(reg)
            }, phase: :pre_verify)
            gates.register(:era_check, Runtime::EraCheck.method(:check_lineage!), phase: :pre_verify) if
              Runtime::EraCheck.lineage_capable_registry?(registry)
          end
        end
      end
    end
  end
end

Hecks::Ports::Persistence.register_plugin(:era, Hecks::Ports::Persistence::Plugins::Era)
