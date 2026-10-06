module Hecks
  module Fuzzing
    # Infers what a sweep target can be checked for from its directory, not a stored list.
    # `modes_to_run = enabled ∩ eligible`: `infer` finds capabilities, `resolve` applies it.
    module TargetCapabilities
      module_function

      # Matches the `[features]` table only, so `[package] name = "rust"` never reads as a feature.
      FEATURES_TABLE = /^\[features\](?:\n(?!\[).*)*$/

      # Both spellings: aggregate-scoped `.persisted_by("PostgresEra")` and the bare
      # domain-level `persisted_by "PostgresEra"`.
      POSTGRES_ERA_BINDING = /persisted_by\s*\(?\s*"PostgresEra"/

      # A local assigned the bare literal on its own line; any other right-hand side is not one.
      POSTGRES_ERA_VARIABLE = /^\s*([a-z_]\w*)\s*=\s*"PostgresEra"\s*(?:#.*)?$/

      # Captures the member a hecksagon attaches; authorization is read off its declaration.
      FRAMEWORK_ATTACHED = /attaches\s*\(?\s*"([^"]+)"/

      # A command-level `role "..."`, the only construct a role check can compare a caller against.
      ROLE_GATED = /^\s*role\s+"/

      TENANT_SCOPED = /\btenant:/

      PROCESS_MANAGER = /^\s*process_manager\s+"/

      # Capabilities each mode needs; an empty list means any target.
      # `resolve` drops `ruby_only` when `differential` resolves too: same seat, Rust is better.
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

      # The modes `hecks quality_control query sweep.run` can run; one absent here is refused at
      # start, not resolved.
      RUNNABLE_MODES = %i[differential ruby_only self_consistency properties_in_differential
                          structural_skip_report adapter_parity_sqlite persistence_parity
                          era_boundary concurrency].freeze

      # Expensive passes run only when named (`--modes`) or as `--all`'s second wave.
      DEFERRED_MODES = %i[persistence_parity adapter_parity_postgres era_boundary concurrency].freeze

      # Reads a target directory to find out which capabilities it actually has.
      #
      # @param domain_path [String] filesystem path to the target domain's directory
      # @param rust_dir [String] path to the Rust project root, checked for a matching
      #   Cargo feature; defaults to this repo's own `rust/` directory
      # @return [Array<String>] the target's capabilities, sorted; a subset of
      #   `sqlite`, `rust`, `postgres_era`, `translations`, `governance`, `role_gated`,
      #   `tenant`, `sagas`
      def infer(domain_path, rust_dir: File.expand_path("../../../rust", __dir__))
        capabilities = %w[sqlite]
        capabilities << "rust" if rust_feature?(domain_path, rust_dir)
        capabilities << "postgres_era" if postgres_era_bound?(domain_path)
        capabilities << "translations" if Dir.glob(File.join(domain_path, "**", "translations", "*.bluebook")).any?
        capabilities << "governance" if authorization_attached?(domain_path)
        capabilities.concat(declared_capabilities(domain_path)).sort
      end

      # The capabilities a target's own bluebooks declare, by the construct each one spells.
      #
      # @param domain_path [String] filesystem path to the target domain's directory
      # @return [Array<String>] `role_gated`, `tenant` and `sagas`, for those the bluebooks declare
      def declared_capabilities(domain_path)
        { "role_gated" => ROLE_GATED, "tenant" => TENANT_SCOPED, "sagas" => PROCESS_MANAGER }
          .select { |_, pattern| any_file?(domain_path, "*.bluebook", pattern) }.keys
      end

      # Answers whether `mode` can run against a target with `capabilities`.
      #
      # @param mode [Symbol, String] a key of `MODE_REQUIREMENTS`, such as `:differential`
      # @param capabilities [Array<String>] the target's capabilities, as `infer` returns
      # @return [Boolean] whether `capabilities` covers every capability `mode` requires
      # @raise [ArgumentError] if `mode` names no entry in `MODE_REQUIREMENTS`
      def eligible?(mode, capabilities)
        required = MODE_REQUIREMENTS.fetch(mode.to_sym) { raise ArgumentError, "unknown sweep mode #{mode.inspect}" }
        (required - capabilities).empty?
      end

      # Filters the enabled modes down to those the target is eligible for, keeping their order.
      #
      # @param enabled [Array<Symbol, String>] modes turned on, in the dial's own
      #   declaration order
      # @param capabilities [Array<String>] the target's capabilities, as `infer` returns
      # @return [Array<Symbol>] `enabled`'s eligible modes, in `enabled`'s order, with
      #   `:ruby_only` dropped whenever `:differential` is also eligible
      def resolve(enabled, capabilities)
        resolved = enabled.map(&:to_sym).select { |mode| eligible?(mode, capabilities) }
        resolved.delete(:ruby_only) if resolved.include?(:differential)
        resolved
      end

      # Answers whether `rust_dir`'s Cargo.toml declares a feature named after
      # `domain_path`'s own directory.
      #
      # @param domain_path [String] filesystem path to the target domain's directory;
      #   its basename, lowercased, is the feature name looked up
      # @param rust_dir [String] path to the Rust project root (holds `Cargo.toml`)
      # @return [Boolean] whether a matching Cargo feature is declared; false if
      #   `rust_dir` has no `Cargo.toml`
      def rust_feature?(domain_path, rust_dir)
        cargo_toml = File.join(rust_dir, "Cargo.toml")
        return false unless File.file?(cargo_toml)

        feature  = File.basename(domain_path).downcase
        features = File.read(cargo_toml)[FEATURES_TABLE] || ""
        features.match?(/^#{Regexp.escape(feature)}\s*=\s*\[\]/)
      end

      # Answers whether any `.hecksagon` under `domain_path` binds PostgresEra,
      # by literal name or through a local variable assigned `"PostgresEra"`.
      #
      # @param domain_path [String] filesystem path to the target domain's directory
      # @return [Boolean] whether a PostgresEra `persisted_by` binding is found
      def postgres_era_bound?(domain_path)
        Dir.glob(File.join(domain_path, "**", "*.hecksagon")).any? do |path|
          text = File.read(path)
          text.match?(POSTGRES_ERA_BINDING) || postgres_era_variable_bound?(text)
        end
      end

      # Answers whether `text` passes a variable assigned `"PostgresEra"` to `persisted_by`.
      #
      # @param text [String] the contents of one `.hecksagon` file
      # @return [Boolean] whether some `persisted_by` call names such a variable
      def postgres_era_variable_bound?(text)
        text.scan(POSTGRES_ERA_VARIABLE).flatten.any? do |name|
          text.match?(/persisted_by\s*\(?\s*#{Regexp.escape(name)}(?!\w)/)
        end
      end

      # Answers whether any `.hecksagon` under `domain_path` attaches a member
      # that provides authorization.
      #
      # The capability label stays "governance" because it is the value stored in the ledger.
      #
      # @param domain_path [String] filesystem path to the target domain's directory
      # @return [Boolean] whether the domain attaches a member that provides the
      #   `Bluebook::Capabilities::AUTHORIZATION` capability
      def authorization_attached?(domain_path)
        attached = Dir.glob(File.join(domain_path, "**", "*.hecksagon"))
                      .flat_map { |path| File.read(path).scan(FRAMEWORK_ATTACHED).flatten }.uniq
        providers = Framework.providers_of(Bluebook::Capabilities::AUTHORIZATION)
        attached.intersect?(providers)
      end

      # Answers whether any file under `domain_path` matching `glob` contains `pattern`.
      #
      # @param domain_path [String] filesystem path to the target domain's directory
      # @param glob [String] a `Dir.glob` pattern relative to `domain_path`, such as
      #   `"*.bluebook"`
      # @param pattern [Regexp] the pattern each matching file's contents is tested against
      # @return [Boolean] whether any matching file's contents match `pattern`
      def any_file?(domain_path, glob, pattern)
        Dir.glob(File.join(domain_path, "**", glob)).any? { |path| File.read(path).match?(pattern) }
      end
    end
  end
end
