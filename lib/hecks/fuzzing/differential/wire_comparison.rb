require "json"
require_relative "../nondeterministic"
require_relative "../rust_gap_manifest"

module Hecks
  module Fuzzing
    module Differential
      # Puts a Ruby replay and a Rust binary's output into the same wire shapes and lists the
      # fields on which they disagree, after dropping what the binary's gap manifest tolerates.
      module WireComparison
        module_function

        # Round-trips `value` through JSON so it compares as plain wire data.
        def jsonify(value) = JSON.parse(JSON.generate(value))

        # Ruby's result in the wire shapes the Rust output is compared against.
        def ruby_view(ruby_result)
          { instances: jsonify(ruby_result[:instances]), events: jsonify(ruby_result[:events]),
            refusals: refusal_rows(ruby_result[:refusals]),
            queries: jsonify(ruby_result[:queries].map { |row| Nondeterministic.strip(row, :query_row) }),
            sagas: jsonify(ruby_result[:sagas]),
            dry_runs: dry_run_rows(ruby_result[:dry_runs]) }
        end

        def dry_run_rows(dry_runs) = dry_runs.map { |d| { "verb" => d[:verb].to_s, "ok" => d[:ok] } }

        def refusal_rows(refusals)
          refusals.map { |r| { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s.split("::").last, "error" => r[:error] } }
        end

        # One `{field:, ruby:, rust:}` entry per wire field on which the two engines disagree.
        def differential_divergences(differ, ruby_result, rust_output, binary)
          view = ruby_view(ruby_result)
          kept = Differential.manifest_partition(RustGapManifest.for_binary(binary),
                                                 ruby_refusals: view[:refusals], rust_refusals: rust_output["refusals"],
                                                 ruby_queries: view[:queries], rust_queries: rust_output["queries"])
          differ.structural_skips.merge(kept[:skipped])
          plain_divergences(view, rust_output) + kept[:stale] + kept_divergences(differ, ruby_result, view, rust_output, kept)
        end

        def plain_divergences(view, rust_output)
          [compare("instances", view[:instances], rust_output["instances"]),
           compare("events", view[:events], rust_output["events"])].compact
        end

        def kept_divergences(differ, ruby_result, view, rust_output, kept)
          [compare("refusals", *kind_rows(kept)),
           compare("queries", *wire_queries(differ, kept)),
           compare("sagas", view[:sagas], rust_output["sagas"]),
           compare("reactions", *reactions(differ, ruby_result, rust_output)),
           compare("dry_runs", view[:dry_runs], Array(rust_output["dry_runs"]).map { |d| d.slice("verb", "ok") })].compact
        end

        def kind_rows(kept)
          by_kind = ->(row) { row.slice("verb", "kind") }
          [kept[:ruby_refusals].map(&by_kind), kept[:rust_refusals].map(&by_kind)]
        end

        def wire_queries(differ, kept)
          wordless = ->(row) { differ.reduce_to_wire_precision(row.except("error", "reference_error")) }
          [kept[:ruby_queries].map(&wordless), kept[:rust_queries].map(&wordless)]
        end

        def reactions(differ, ruby_result, rust_output)
          cross_domain = differ.cross_domain_policy_names(rust_output)
          [jsonify(ruby_result[:reactions]).reject { |r| cross_domain.include?(r["policy"]) },
           rust_output.fetch("reactions")]
        end

        def compare(field, ruby, rust) = ruby == rust ? nil : { field: field, ruby: ruby, rust: rust }
      end
    end
  end
end
