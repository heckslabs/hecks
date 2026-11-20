require "json"
require_relative "replay"
require_relative "properties"
require_relative "self_consistency"
require_relative "rust_gap_manifest"
require_relative "../rust_build/kernel_input"
require_relative "nondeterministic"
require_relative "differential/wire_comparison"
require_relative "differential/serve_engine"
require_relative "replay/engine/kernel"

module Hecks
  module Fuzzing
    # The Ruby-vs-Rust comparison of one generated sequence, shared by the QualityControl sweep
    # (`hecks quality_control sweep.run`) and `hecks quality_control
    # target.check_generated_domains --rust`.
    #
    # `differ` is duck-typed (the `RustConformanceHelpers` comparison helpers plus a
    # `structural_skips` set) so lib never requires spec/.
    module Differential
      module_function

      # Drops both sides' rows for verbs `gaps` declares not generated; every other
      # divergence, however worded, stays in. A tolerated verb Rust nonetheless answered
      # is reported as stale, so a wrong manifest cannot silently hold.
      #
      # @param gaps [Hecks::Fuzzing::RustGapManifest] the compiled binary's manifest
      # @param ruby_refusals [Array<Hash>] Ruby's own refusal rows for this history
      # @param rust_refusals [Array<Hash>] the Rust binary's own refusal rows
      # @param ruby_queries [Array<Hash>] Ruby's own query rows for this history
      # @param rust_queries [Array<Hash>] the Rust binary's own query rows
      # @return [Hash] the four row lists with tolerated verbs removed, `skipped:` (a
      #   `Set<String>` of tolerated verbs reached) and `stale:` (`Array<Hash>` divergences)
      def manifest_partition(gaps, ruby_refusals:, rust_refusals:, ruby_queries:, rust_queries:)
        declared = ->(row) { gaps.not_generated?(wire_verb(row)) }
        lists = { ruby_refusals: ruby_refusals, rust_refusals: rust_refusals,
                  ruby_queries: ruby_queries, rust_queries: rust_queries }
        reached = (ruby_refusals + rust_refusals + ruby_queries).select(&declared)
        lists.transform_values { |rows| rows.reject(&declared) }
             .merge(skipped: reached.to_set { |row| wire_verb(row) },
                    stale:   stale_rows(gaps, rust_queries.select(&declared)))
      end

      # The verb a refusal row names, or the query a query row names.
      def wire_verb(row) = row.key?("verb") ? row["verb"] : row["query"]

      # One divergence per tolerated query the Rust binary answered anyway.
      def stale_rows(gaps, answered)
        answered.map do |row|
          { field: "manifest", verb: row["query"],
            detail: "#{row["query"]} is declared generated: false in manifest.json " \
                    "(#{gaps.not_generated(row["query"]).values_at("gap_class", "construct").join("/")}), " \
                    "but the Rust binary answered it — regenerate with hecks Build.project_rust! domain.value=…" }
        end
      end

      # Runs the standard property battery on a replayed history.
      #
      # @param history [Hash] as returned by `Replay.call`
      # @return [Array<Hash>] one `{field:, detail:}` entry per failed property
      def property_divergences(history)
        Properties.check(history).reject { |_, result| result == true }
                  .map { |name, message| { field: name.to_s, detail: message } }
      end

      # Flattens `history[:self_consistency]`'s per-check divergence lists.
      #
      # @param history [Hash] as returned by `Replay.call`, optionally with `:self_consistency`
      # @return [Array<Hash>] empty if `history` carries no `:self_consistency`
      def self_consistency_divergences(history)
        return [] unless history[:self_consistency]

        history[:self_consistency].values.flatten(1)
      end

      # Replays `steps` on Ruby and on `engine`; a binary path runs as `Engine::Kernel`.
      #
      # @param differ [Object] duck-typed `RustConformanceHelpers` interface
      # @param domain_path [String] the domain directory to replay
      # @param steps [Array<Hash>] the step sequence replayed on both engines
      # @param engine [#call, String] answers `call(domain_path, steps)` and `#binary`, as
      #   {ServeEngine} does; or a binary path, the batch fallback until ADR 0188 step 3
      # @param options [Hash] `modes:` (required), Symbols among `:differential`,
      #   `:self_consistency`, `:properties_in_differential` and `:adapter_parity_sqlite`;
      #   `adapter_parity_sqlite:`, a Proc or nil
      # @return [Hash{Symbol => Array<Hash>}] one divergence list per active mode
      def diff(differ, domain_path, steps, engine, **options)
        modes, adapter_parity = diff_options(options)
        ruby_result = Replay.call(domain_path, steps, self_consistency: modes.include?(:self_consistency))
        outcomes = mode_outcomes(ruby_result, modes, adapter_parity)
        engine = engine_for(engine)
        outcomes.merge(engine_outcomes(differ, ruby_result, engine, modes) { engine.call(domain_path, steps) })
      end

      # @param engine [#call, String] an engine, or a binary path to run as `Engine::Kernel`
      # @return [#call] the engine
      def engine_for(engine) = engine.is_a?(String) ? Engine::Kernel.new(engine) : engine

      # The outcomes of the engine's run (the block), or one `process` divergence when it fails.
      def engine_outcomes(differ, ruby_result, engine, modes)
        rust_outcomes(differ, ruby_result, yield, engine.binary, modes.include?(:self_consistency))
      rescue Engine::Kernel::Failed => e
        { differential: [{ field: "process", detail: "rust binary failed: #{e.message}" }] }
      end

      # Splits the keywords of `diff` into the modes and the parity hook, refusing any other.
      def diff_options(options)
        unknown = options.keys - [:modes, :adapter_parity_sqlite]
        raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" if unknown.any?

        [options.fetch(:modes) { raise ArgumentError, "missing keyword: :modes" }, options[:adapter_parity_sqlite]]
      end

      # The `:differential` outcome, plus `:self_consistency` when that mode is active.
      def rust_outcomes(differ, ruby_result, rust_output, binary, self_consistency)
        live_instances = WireComparison.jsonify(rust_output["instances"]) if self_consistency
        differ.strip_emitted_flags!(rust_output["instances"])
        differ.strip_emitted_flags!(rust_output["queries"])
        differ.strip_occurred_at!(rust_output["events"])
        outcomes = { differential: WireComparison.differential_divergences(differ, ruby_result, rust_output, binary) }
        outcomes[:self_consistency] = rust_self_consistency(ruby_result, binary, differ, live_instances) if self_consistency
        outcomes
      end

      # The modes that run on the Ruby side alone, before the binary is touched.
      def mode_outcomes(ruby_result, modes, adapter_parity)
        outcomes = {}
        outcomes[:properties_in_differential] = property_divergences(ruby_result) if modes.include?(:properties_in_differential)
        outcomes[:adapter_parity_sqlite] = adapter_parity.call if modes.include?(:adapter_parity_sqlite) && adapter_parity
        outcomes
      end

      def rust_self_consistency(ruby_result, binary, differ, rust_live_instances)
        self_consistency_divergences(ruby_result) +
          SelfConsistency.check_rust_rehydration(binary, differ, rust_live_instances) +
          SelfConsistency.check_rust_idempotency(binary, differ, rust_live_instances)
      end
    end
  end
end
