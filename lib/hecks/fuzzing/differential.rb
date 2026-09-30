require "json"
require "open3"
require_relative "replay"
require_relative "properties"
require_relative "self_consistency"
require_relative "rust_gap_manifest"
require_relative "nondeterministic"

module Hecks
  module Fuzzing
    # The Ruby-vs-Rust comparison of one generated sequence, shared by the QualityControl sweep
    # (`hecks quality_control ask run`) and `hecks quality_control check_generated_domains --rust`.
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
        verb_of  = ->(row) { row.key?("verb") ? row["verb"] : row["query"] }
        declared = ->(row) { gaps.not_generated?(verb_of.call(row)) }
        stale = rust_queries.select(&declared).map do |row|
          { field: "manifest", verb: row["query"],
            detail: "#{row['query']} is declared generated: false in manifest.json " \
                    "(#{gaps.not_generated(row['query']).values_at('gap_class', 'construct').join('/')}), " \
                    "but the Rust binary answered it — regenerate with hecks project_rust" }
        end
        reached = (ruby_refusals + rust_refusals + ruby_queries).select(&declared)
        { ruby_refusals: ruby_refusals.reject(&declared), rust_refusals: rust_refusals.reject(&declared),
          ruby_queries: ruby_queries.reject(&declared), rust_queries: rust_queries.reject(&declared),
          skipped: reached.to_set(&verb_of), stale: stale }
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

      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      # rubocop:disable-next Metrics/MethodLength
      # @param differ [Object] duck-typed `RustConformanceHelpers` interface
      # @param domain_path [String] the domain directory to replay
      # @param steps [Array<Hash>] the step sequence replayed on both engines
      # @param binary [String] the compiled Rust conformance binary
      # @param modes [Array<Symbol>] `:differential` (always run), `:self_consistency`,
      #   `:properties_in_differential`, `:adapter_parity_sqlite`
      # @param adapter_parity_sqlite [Proc, nil] the caller's comparison; `nil` skips the mode
      # @return [Hash{Symbol => Array<Hash>}] one divergence list per active mode
      def diff(differ, domain_path, steps, binary, modes:, adapter_parity_sqlite: nil)
        self_consistency = modes.include?(:self_consistency)
        ruby_result    = Replay.call(domain_path, steps, self_consistency: self_consistency)
        ruby_instances = JSON.parse(JSON.generate(ruby_result[:instances]))
        ruby_events    = JSON.parse(JSON.generate(ruby_result[:events]))
        ruby_refusals  = ruby_result[:refusals].map do |r|
          { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s.split("::").last, "error" => r[:error] }
        end
        ruby_queries  = JSON.parse(JSON.generate(ruby_result[:queries].map { |row| Nondeterministic.strip(row, :query_row) }))
        ruby_sagas    = JSON.parse(JSON.generate(ruby_result[:sagas]))
        ruby_dry_runs = ruby_result[:dry_runs].map { |d| { "verb" => d[:verb].to_s, "ok" => d[:ok] } }

        outcomes = {}
        outcomes[:properties_in_differential] = property_divergences(ruby_result) if modes.include?(:properties_in_differential)
        if modes.include?(:adapter_parity_sqlite) && adapter_parity_sqlite
          outcomes[:adapter_parity_sqlite] = adapter_parity_sqlite.call
        end

        stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
        unless status.success?
          return outcomes.merge(differential: [{ field:  "process",
                                                 detail: "rust binary exited #{status.exitstatus}: #{stdout}" }])
        end

        rust_output = JSON.parse(stdout)
        rust_live_instances = JSON.parse(JSON.generate(rust_output["instances"])) if self_consistency
        differ.strip_emitted_flags!(rust_output["instances"])
        differ.strip_emitted_flags!(rust_output["queries"])
        differ.strip_occurred_at!(rust_output["events"])

        divergences = []
        divergences << { field: "instances", ruby: ruby_instances, rust: rust_output["instances"] } \
          unless rust_output["instances"] == ruby_instances
        divergences << { field: "events", ruby: ruby_events, rust: rust_output["events"] } \
          unless rust_output["events"] == ruby_events

        kept = manifest_partition(RustGapManifest.for_binary(binary),
                                  ruby_refusals: ruby_refusals, rust_refusals: rust_output["refusals"],
                                  ruby_queries: ruby_queries, rust_queries: rust_output["queries"])
        differ.structural_skips.merge(kept[:skipped])
        divergences.concat(kept[:stale])

        by_kind = ->(r) { r.slice("verb", "kind") }
        rust_refusals      = kept[:rust_refusals].map(&by_kind)
        kept_ruby_refusals = kept[:ruby_refusals].map(&by_kind)
        divergences << { field: "refusals", ruby: kept_ruby_refusals, rust: rust_refusals } \
          unless rust_refusals == kept_ruby_refusals

        wordless          = ->(row) { differ.reduce_to_wire_precision(row.except("error", "reference_error")) }
        rust_queries      = kept[:rust_queries].map(&wordless)
        kept_ruby_queries = kept[:ruby_queries].map(&wordless)
        divergences << { field: "queries", ruby: kept_ruby_queries, rust: rust_queries } \
          unless rust_queries == kept_ruby_queries

        divergences << { field: "sagas", ruby: ruby_sagas, rust: rust_output["sagas"] } \
          unless rust_output["sagas"] == ruby_sagas

        cross_domain = differ.cross_domain_policy_names(rust_output)
        kept_ruby_reactions = JSON.parse(JSON.generate(ruby_result[:reactions]))
                                  .reject { |r| cross_domain.include?(r["policy"]) }
        rust_reactions = rust_output.fetch("reactions")
        divergences << { field: "reactions", ruby: kept_ruby_reactions, rust: rust_reactions } \
          unless rust_reactions == kept_ruby_reactions

        rust_dry_runs = Array(rust_output["dry_runs"]).map { |d| d.slice("verb", "ok") }
        divergences << { field: "dry_runs", ruby: ruby_dry_runs, rust: rust_dry_runs } \
          unless rust_dry_runs == ruby_dry_runs
        outcomes[:differential] = divergences

        if self_consistency
          outcomes[:self_consistency] =
            self_consistency_divergences(ruby_result) +
            SelfConsistency.check_rust_rehydration(binary, differ, rust_live_instances) +
            SelfConsistency.check_rust_idempotency(binary, differ, rust_live_instances)
        end

        outcomes
      end
    end
  end
end
