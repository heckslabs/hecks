module Hecks
  module Fuzzing
    # WHAT A SWEEP TARGET CAN ACTUALLY BE CHECKED FOR, read off the
    # filesystem — never off a stored list.
    #
    # `bin/qa_sweep` used to decide its ONE comparison mode inline: "is
    # there a Cargo feature named after this directory? then
    # `:differential`, else `:ruby_only`", and a separate hand-typed abort
    # for `--persistence-parity` ("does any .hecksagon bind PostgresEra?").
    # Every further mode the practice adds (era boundary, concurrency, a
    # WASM front) would have grown one more inline `if`, each one a
    # policy decision hiding in a script. This module is those decisions
    # as DATA: `MODE_REQUIREMENTS` says which capabilities each mode
    # needs, `infer` says which capabilities a target's own directory
    # actually has, and `resolve` is the one rule that joins them —
    # `modes_to_run = enabled ∩ eligible`.
    #
    # INFERENCE DECIDES; A STORED LIST ONLY RECORDS. `Target.capabilities`
    # (qa/bluebook/quality_control.bluebook, once PR-1's era lands) is
    # written by the runner from exactly this inference at release time
    # so `Target.EligibleFor(mode)` can AUDIT the rotation from the
    # ledger alone — but the runner re-infers every sweep, because a
    # stored list that lags yesterday's Cargo feature is precisely the
    # "quiet divergence" (the chapter's own opening comment) this whole
    # practice exists to hunt. Nothing here ever reads the ledger.
    #
    # EVERY REGEX IS ONE THE HARNESS ALREADY OWNED, moved here rather than
    # re-derived, and each one's provenance is named beside it so a
    # future edit to the original site is a visible drift, not a silent
    # one: the Cargo feature line (`RustConformanceHelpers#build_rust_for`),
    # the PostgresEra binding (`bin/qa_sweep`'s old `POSTGRES_ERA_BINDING`),
    # the translations glob (`IsolatedBoot#strip_translations!`).
    module TargetCapabilities
      module_function

      # `RustConformanceHelpers#build_rust_for`'s own test, scoped to the
      # `[features]` table the way `bin/project_rust`'s Cargo sync scopes
      # its own lookup (a `[package] name = "rust"` line must never read
      # as a feature named `rust`).
      FEATURES_TABLE = /^\[features\](?:\n(?!\[).*)*$/

      # `bin/qa_sweep`'s former `POSTGRES_ERA_BINDING` — both spellings
      # `IsolatedBoot#rewrite_bindings!` has to catch: aggregate-scoped
      # (`Directory::Member.persisted_by("PostgresEra")`) and the bare
      # domain-level default (`persisted_by "PostgresEra"`).
      POSTGRES_ERA_BINDING = /persisted_by\s*\(?\s*"PostgresEra"/

      # `HecksagonBuilder#uses_framework` — the one line that attaches
      # Governance's own `RoleAssignment` lookup to a domain's `role` checks
      # (`CommandRules::Authorization#governance_attached?`).
      GOVERNANCE_ATTACHED = /uses_framework\s*\(?\s*"Governance"/

      # A command-level `role "..."` — the only construct
      # `refuse_role_mismatch` ever has anything to check a caller against.
      ROLE_GATED = /^\s*role\s+"/

      # `authorize :vault_access, tenant: :branch_code`
      # (examples/banking/bluebook/safe_deposit_boxes.bluebook) — the one
      # `tenant:` spelling the corpus has.
      TENANT_SCOPED = /\btenant:/

      PROCESS_MANAGER = /^\s*process_manager\s+"/

      # WHICH CAPABILITIES EACH MODE NEEDS BEFORE IT CAN SAY ANYTHING TRUE
      # ABOUT A TARGET. An empty list means "any target at all" — every
      # domain boots under Memory, so Ruby-only properties and the
      # self-consistency pass are always answerable. `ruby_only` is listed
      # requirement-free on purpose and then EXCLUDED by `resolve` whenever
      # `differential` resolved too: they are the same seat, and a compiled
      # Rust binary is strictly the better occupant (item 1 of the
      # detection plan folded the Ruby-only property battery INTO the
      # differential seat, so nothing is lost by the exclusion).
      #
      # The four `false`-by-default modes in `QualityControlDials::MODES`
      # (`adapter_parity_postgres`, `era_boundary`, `concurrency`,
      # `wasm_front`) are named here with their requirements even though
      # nothing runs them yet — so `resolved modes:` can already say, per
      # target, which of them WOULD be eligible the day a human flips the
      # dial, and so flipping it is a one-line data change rather than a
      # code change plus a data change.
      MODE_REQUIREMENTS = {
        differential:               %w[rust],
        ruby_only:                  [],
        self_consistency:           [],
        properties_in_differential: %w[rust],
        structural_skip_report:     %w[rust],
        adapter_parity_sqlite:      %w[sqlite],
        persistence_parity:         %w[postgres_era],
        adapter_parity_postgres:    %w[postgres_era],
        era_boundary:               %w[translations postgres_era],
        concurrency:                %w[postgres_era],
        wasm_front:                 %w[rust]
      }.freeze

      # MODES THAT NAME A SEPARATE, EXPENSIVE PASS OF THEIR OWN rather than
      # an extra check folded into the ordinary per-seed loop —
      # `bin/qa_sweep` runs these only when asked by name (`--modes
      # persistence_parity`, or its older alias `--persistence-parity`) or
      # as `--all`'s own second wave, never silently inside a plain
      # single-target sweep (the seed cap `PERSISTENCE_PARITY_SEED_CAP`
      # exists because that pass pays for real Postgres I/O per dispatch).
      DEFERRED_MODES = %i[persistence_parity adapter_parity_postgres era_boundary concurrency].freeze

      # Sorted, plain strings — comma-joined by the runner into the
      # `Target.Release(capabilities:)` value object and printed verbatim
      # on the `resolved modes:` line, so the same spelling is what a
      # human reads, what `--all` parses back, and what the ledger stores.
      def infer(domain_path, rust_dir: File.expand_path("../../../rust", __dir__))
        capabilities = %w[sqlite]
        capabilities << "rust" if rust_feature?(domain_path, rust_dir)
        capabilities << "postgres_era" if any_file?(domain_path, "*.hecksagon", POSTGRES_ERA_BINDING)
        capabilities << "translations" if Dir.glob(File.join(domain_path, "**", "translations", "*.bluebook")).any?
        capabilities << "governance" if any_file?(domain_path, "*.hecksagon", GOVERNANCE_ATTACHED)
        capabilities << "role_gated" if any_file?(domain_path, "*.bluebook", ROLE_GATED)
        capabilities << "tenant" if any_file?(domain_path, "*.bluebook", TENANT_SCOPED)
        capabilities << "sagas" if any_file?(domain_path, "*.bluebook", PROCESS_MANAGER)
        capabilities.sort
      end

      def eligible?(mode, capabilities)
        required = MODE_REQUIREMENTS.fetch(mode.to_sym) { raise ArgumentError, "unknown sweep mode #{mode.inspect}" }
        (required - capabilities).empty?
      end

      # THE ONE RULE. `enabled` is whatever the dial (or `--modes`) turned
      # on, in the dial's own declaration order — that order is preserved
      # so the printed line reads the same way the dial does. Then the
      # single exclusion named on `MODE_REQUIREMENTS`.
      def resolve(enabled, capabilities)
        resolved = enabled.map(&:to_sym).select { |mode| eligible?(mode, capabilities) }
        resolved.delete(:ruby_only) if resolved.include?(:differential)
        resolved
      end

      def rust_feature?(domain_path, rust_dir)
        cargo_toml = File.join(rust_dir, "Cargo.toml")
        return false unless File.file?(cargo_toml)

        feature  = File.basename(domain_path).downcase
        features = File.read(cargo_toml)[FEATURES_TABLE] || ""
        features.match?(/^#{Regexp.escape(feature)}\s*=\s*\[\]/)
      end

      def any_file?(domain_path, glob, pattern)
        Dir.glob(File.join(domain_path, "**", glob)).any? { |path| File.read(path).match?(pattern) }
      end
    end
  end
end
