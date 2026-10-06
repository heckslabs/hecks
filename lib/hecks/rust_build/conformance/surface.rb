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
          dry_runs = dry_run_surface(result[:dry_runs])
          surface["dry_runs"] = dry_runs unless dry_runs.empty?
          surface
        end

        def refusal_surface(refusal)
          { "verb" => refusal[:verb], "error" => refusal[:error], "kind" => refusal[:kind]&.split("::")&.last }
        end

        # `verb` and `ok` only, as `Hecks::Fuzzing::Differential` compares; omitted when none.
        def dry_run_surface(dry_runs)
          dry_runs.map { |dry| { "verb" => dry[:verb].to_s, "ok" => dry[:ok] } }
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
