# frozen_string_literal: true

require "json"

module Hecks
  module RustBuild
    module Conformance
      # The comparable surface of a run: what Ruby and a Rust artifact must both reproduce, with
      # what only one side carries stripped away.
      module Surface
        # The refusal kinds are not compared for ad-hoc filter steps: C8.3
        # (docs/semantics/bluebook-semantics.md) is open (RuntimeError in Ruby, TypeMismatch in
        # Rust), and only the message is byte-exact.
        FILTER_VERB = "filter "

        module_function

        # @param result [Hash] `Fuzzing::Replay`'s answer
        # @return [Hash{String => Object}] the surface a Rust artifact must reproduce
        def comparable(result)
          surface = {
            "instances" => result[:instances].transform_values { |state| JSON.parse(JSON.generate(state)) },
            "events"    => result[:events].map { |event| event_surface(event) },
            "refusals"  => result[:refusals].map { |refusal| refusal_surface(refusal) }
          }
          surface.merge(read_only_surface(result))
        end

        # The dry runs and validations, each omitted when the script has none.
        def read_only_surface(result)
          dry_runs = dry_run_surface(result[:dry_runs], result[:dry_run_traces])
          validations = JSON.parse(JSON.generate(result[:validations] || []))
          { "dry_runs" => dry_runs, "validations" => validations }.reject { |_, entries| entries.empty? }
        end

        def refusal_surface(refusal)
          { "verb" => refusal[:verb], "error" => refusal[:error], "kind" => refusal[:kind]&.split("::")&.last }
        end

        # The stages whose every refusal both engines list.
        COLLECTED_STAGES = %w[givens ensures invariants].freeze

        # In the arguments stage Rust lists the unknown and absent names, one refusal each; a
        # coercion mismatch it raises alone, so a run with one is compared on `ok` alone.
        LISTED_ARGUMENT_CLASSES = %w[AbsentArgument UnknownArgument].freeze

        # `verb` and `ok`, as `Hecks::Fuzzing::Differential` compares, and for a run refused where
        # both engines list every refusal, each one's kind, stage, attribute, path and rule.
        def dry_run_surface(dry_runs, traces = [])
          dry_runs.zip(traces).map do |dry, trace|
            reasons = trace&.dig(:validation, :reasons) unless dry[:ok]
            { "verb" => dry[:verb].to_s, "ok" => dry[:ok] }.merge(collected_refusals(reasons))
          end
        end

        # @param reasons [Array<Array>, nil] each as `[kind, stage, attribute, path, rule, class]`
        # @return [Hash] `{"refusals" => reasons}` without the class, if both engines list them all
        def collected_refusals(reasons)
          return {} unless reasons&.any? && listed_in_full?(reasons)

          { "refusals" => reasons.map { |reason| reason.first(5) } }
        end

        def listed_in_full?(reasons)
          stage = reasons.first[1]
          return true if COLLECTED_STAGES.include?(stage)

          stage == "arguments" && reasons.all? { |reason| LISTED_ARGUMENT_CLASSES.include?(reason.last) }
        end

        def event_surface(event)
          { "name" => event[:name], "aggregate" => event[:aggregate], "id" => event[:id].to_s,
            "payload" => JSON.parse(JSON.generate(event[:payload])) }
        end

        # Strips what a Rust run carries that Ruby has no analog for: `emitted_*` snapshot flags
        # (ADR 0048) and the wall-clock `occurred_at` stamp two runs can never match.
        def normalize(theirs)
          strip_snapshot_flags(theirs["instances"])
          strip_timestamps(theirs["events"])
          theirs
        end

        def strip_snapshot_flags(instances)
          return unless instances.is_a?(Hash)

          instances.each_value do |record|
            record.reject! { |key, _| key.start_with?("emitted_") } if record.is_a?(Hash)
          end
        end

        def strip_timestamps(events)
          return unless events.is_a?(Array)

          events.each { |event| event.delete("occurred_at") if event.is_a?(Hash) }
        end

        def drop_filter_kinds(side)
          return unless side["refusals"].is_a?(Array)

          side["refusals"].each { |r| r.delete("kind") if r.is_a?(Hash) && r["verb"].to_s.start_with?(FILTER_VERB) }
        end
      end
    end
  end
end
