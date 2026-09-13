require "json"
require "open3"
require_relative "replay"
require_relative "properties"
require_relative "self_consistency"

module Hecks
  module Fuzzing
    # THE RUBY-VS-RUST COMPARISON OF ONE GENERATED SEQUENCE — moved here,
    # unchanged, out of `bin/qa_sweep`'s own `diff_ruby_vs_rust` so a second
    # caller (`bin/qa_generated_domains --rust`, which compares domains the
    # generator wrote rather than ones on the rotation) runs the SAME
    # comparison rather than a re-derived one. `bin/qa_sweep` delegates to
    # it; its own comments on the known-gap filtering, the wire-precision
    # reduction and the deep copy taken before `strip_emitted_flags!` apply
    # here word for word.
    #
    # `differ` is anything answering `RustConformanceHelpers`' comparison
    # helpers (spec/support/rust_conformance_helpers.rb) plus a
    # `structural_skips` set — duck-typed, so lib never requires spec/.
    #
    # RETURNS ONE DIVERGENCE LIST PER ACTIVE MODE — `{ differential: [...],
    # self_consistency: [...], properties_in_differential: [...],
    # adapter_parity_sqlite: [...] }`, keys present only for the modes in
    # `modes:` (`differential` always). `adapter_parity_sqlite:` is the
    # caller's own callable, because which two adapters that mode pairs is
    # the caller's dial, not this module's.
    module Differential
      module_function

      def property_divergences(history)
        Properties.check(history).reject { |_, result| result == true }
                  .map { |name, message| { field: name.to_s, detail: message } }
      end

      def self_consistency_divergences(history)
        return [] unless history[:self_consistency]

        history[:self_consistency].values.flatten(1)
      end

      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      # rubocop:disable-next Metrics/MethodLength
      def diff(differ, domain_path, steps, binary, modes:, adapter_parity_sqlite: nil)
        self_consistency = modes.include?(:self_consistency)
        ruby_result    = Replay.call(domain_path, steps, self_consistency: self_consistency)
        ruby_instances = JSON.parse(JSON.generate(ruby_result[:instances]))
        ruby_events    = JSON.parse(JSON.generate(ruby_result[:events]))
        ruby_refusals  = ruby_result[:refusals].map do |r|
          { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s.split("::").last, "error" => r[:error] }
        end
        ruby_queries  = JSON.parse(JSON.generate(ruby_result[:queries].map { |row| row.except(:instances_at) }))
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

        by_kind = ->(r) { r.slice("verb", "kind") }
        gap     = ->(r) { differ.known_refusal_gap?(r) || differ.structural_refusal_gap?(r) }
        rust_refusals       = rust_output["refusals"].reject(&gap).map(&by_kind)
        kept_ruby_refusals  = ruby_refusals.reject(&gap).map(&by_kind)
        divergences << { field: "refusals", ruby: kept_ruby_refusals, rust: rust_refusals } \
          unless rust_refusals == kept_ruby_refusals

        wordless      = ->(row) { differ.reduce_to_wire_precision(row.except("error", "reference_error")) }
        not_generated = differ.structurally_refused_verbs(rust_output)
        differ.structural_skips.merge(not_generated)
        rust_queries      = rust_output["queries"].reject(&gap).map(&wordless)
        kept_ruby_queries = ruby_queries.reject { |row| gap.call(row) || not_generated.include?(row["query"]) }.map(&wordless)
        divergences << { field: "queries", ruby: kept_ruby_queries, rust: rust_queries } \
          unless rust_queries == kept_ruby_queries

        divergences << { field: "sagas", ruby: ruby_sagas, rust: rust_output["sagas"] } \
          unless rust_output["sagas"] == ruby_sagas

        cross_domain = differ.cross_domain_policy_names(rust_output)
        kept_ruby_reactions = JSON.parse(JSON.generate(ruby_result[:reactions]))
                                  .reject { |r| cross_domain.include?(r["policy"]) || differ.known_reaction_gap?(r) }
        rust_reactions = rust_output.fetch("reactions").reject { |r| differ.known_reaction_gap?(r) }
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
