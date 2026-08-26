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
        # ADR 0033 — requiring THIS FILE is installing the plugin. Nothing in
        # Hecks core requires it; an app that binds `PostgresEra`, or wants
        # schema-translation support at all, requires it explicitly — the
        # same shape every adapter-specific spec fixture already uses to
        # load one particular `.adapter` file rather than all of them.
        module Era
          module_function

          # `Runtime::Loader.run_boot_gates!` asks every loaded persistence
          # plugin to contribute here, generically — it never mentions
          # `EraCheck` or "era" by name. Two gates, both `:pre_verify`:
          #
          # `:era_compute_rules` — unconditional, whenever this plugin is
          # loaded at all. A `compute`/`rekey` rule requires Postgres
          # whatever adapter is actually bound (ADR 0031's own reasoning,
          # unchanged) — this is the rich, adapter-aware version of that
          # check; `Runtime::Loader`'s own structural backstop (plain
          # `Bluebook::Translation` data, no plugin-specific class) only
          # ever fires when NO persistence plugin is loaded at all.
          #
          # `:era_check` — conditional, exactly ADR 0031's own gate,
          # unchanged: registered only when this registry has an aggregate
          # actually bound to a lineage-capable adapter.
          def contribute_boot_gates(registry, gates)
            gates.register(:era_compute_rules, ->(reg, _dir) { Runtime::EraCheck.check_compute_rules_for_registry!(reg) }, phase: :pre_verify)
            gates.register(:era_check, Runtime::EraCheck.method(:check_lineage!), phase: :pre_verify) if
              Runtime::EraCheck.lineage_capable_registry?(registry)
          end
        end
      end
    end
  end
end

Hecks::Ports::Persistence.register_plugin(:era, Hecks::Ports::Persistence::Plugins::Era)
