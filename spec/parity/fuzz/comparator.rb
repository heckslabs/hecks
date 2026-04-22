# Hecks::Parity::Fuzz::Comparator
#
# Purpose: decide whether a runner's ruby/rust heki trees agree.
# Uses the canonicalizer for field-level comparison, and the
# runner Result's error strings for runtime-level comparison.
#
# A "divergence" is any of:
#   1. One side errored AND the other didn't (runtime-level drift)
#   2. Both sides ran to completion but canonical JSONs differ
#
# Agreement: both errored OR both ran cleanly with identical
# canonical JSON. Both-errored is treated as agreement because the
# fuzzer can surface pathological-shape generation as a different
# class of bug, and many generator rejection cases have matching
# errors on both sides (expected).
#
# Usage:
#   verdict = Comparator.compare(runner_result, domain)
#   verdict.status   # :agree | :diverge
#   verdict.reason   # String (why divergent, for failure artifact)
#   verdict.ruby_canonical / verdict.rust_canonical
#
# [antibody-exempt: differential fuzzer per i30 plan — retires when
# fuzzer ports to bluebook-dispatched form via hecks-life run]

require_relative "canonicalizer"

module Hecks
  module Parity
    module Fuzz
      module Comparator
        Verdict = Struct.new(:status, :reason, :ruby_canonical, :rust_canonical, keyword_init: true)

        module_function

        def compare(runner_result, domain)
          type_map = domain ? Canonicalizer.build_type_map(domain) : {}
          ruby_json = Canonicalizer.canonicalize(runner_result.ruby_dir, type_map)
          rust_json = Canonicalizer.canonicalize(runner_result.rust_dir, type_map)

          ruby_err = runner_result.ruby_error
          rust_err = runner_result.rust_error

          # Runtime-level drift: one side errored, the other didn't.
          if ruby_err && !rust_err
            return Verdict.new(status: :diverge,
                               reason: "ruby errored: #{ruby_err}; rust clean",
                               ruby_canonical: ruby_json, rust_canonical: rust_json)
          end
          if rust_err && !ruby_err
            return Verdict.new(status: :diverge,
                               reason: "rust errored: #{rust_err}; ruby clean",
                               ruby_canonical: ruby_json, rust_canonical: rust_json)
          end

          # Both errored: treat as agreement (pathological-shape generator
          # output rather than runtime drift).
          if ruby_err && rust_err
            return Verdict.new(status: :agree,
                               reason: "both errored (expected — pathological shape)",
                               ruby_canonical: ruby_json, rust_canonical: rust_json)
          end

          if ruby_json == rust_json
            Verdict.new(status: :agree, reason: "clean match",
                        ruby_canonical: ruby_json, rust_canonical: rust_json)
          else
            Verdict.new(status: :diverge,
                        reason: "canonical JSON differs",
                        ruby_canonical: ruby_json, rust_canonical: rust_json)
          end
        end

        # Compact side-by-side diff of two canonical JSON strings, for
        # the failure artifact log. Not a general JSON-diff — just a
        # visual aid. Pretty-prints both and shows each line with
        # marker so the user can eyeball drift.
        def pretty_diff(ruby_json, rust_json)
          ruby_pretty = JSON.pretty_generate(JSON.parse(ruby_json))
          rust_pretty = JSON.pretty_generate(JSON.parse(rust_json))
          out = +"--- ruby ---\n#{ruby_pretty}\n--- rust ---\n#{rust_pretty}\n"
          out
        rescue JSON::ParserError => e
          "ruby: #{ruby_json}\nrust: #{rust_json}\n(pretty-parse failed: #{e.message})"
        end
      end
    end
  end
end
