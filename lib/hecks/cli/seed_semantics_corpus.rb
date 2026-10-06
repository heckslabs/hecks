# frozen_string_literal: true

require "json"
require_relative "../../hecks"
require_relative "../fuzzing"

module Hecks
  module CLI
    # The command behind `hecks test_suite_run.seed_semantics_corpus`: seeds (or re-seeds) the
    # `expect` block of corpus fixtures from the Ruby runtime. Review the result
    # against `docs/semantics/bluebook-semantics.md` before committing.
    #
    # Seeds `spec/corpus/semantics/` and the conformance corpus ({FULL_SCRIPTS} plus
    # `spec/corpus/rust_conformance/`, whose `expect` also freezes more).
    #
    #   hecks test_suite_run.seed_semantics_corpus   # fill what lacks an expect
    #   SEED=refusal_kind_lifecycle hecks test_suite_run.seed_semantics_corpus   # re-seed one
    #
    # The seeded expectation is the definition, not a recording: both runtimes are compared to it.
    # `occurred_at` is stripped from events (C7.3/C9.1); refusals keep verb, error and kind (C8.2).
    module SeedSemanticsCorpus
      module_function

      # Full corpus scripts held to the conformance bar, keyed by file, valued by domain.
      FULL_SCRIPTS = {
        "spec/corpus/banking.json" => "examples/banking",
        "spec/corpus/chess.json"   => "examples/chess"
      }.freeze

      # The `expect` keys a conformance fixture freezes beyond the semantics three.
      CONFORMANCE_KEYS = %w[queries sagas dry_runs reactions].freeze

      # Seeds the fixtures that need it and reports which.
      #
      # @param root [String] the checkout whose `spec/corpus/semantics/` is seeded
      # @param env [Hash{String => String}] `SEED` names the one fixture to re-seed
      # @param out [IO] where the report goes
      # @return [Integer] the exit status, always 0
      def call(root:, env: ENV, out: $stdout)
        only = env.fetch("SEED", nil)
        seeded = corpus_paths(root).filter_map { |path, domain, full| seed_fixture(root, path, domain, full, only) }
        report(out, seeded)
        0
      end

      # Seeds one fixture unless it already carries an expect (or is not the one named).
      #
      # @api private
      # @return [String, nil] the fixture's name when it was written
      def seed_fixture(root, path, domain, full, only)
        fixture = JSON.parse(File.read(path))
        name = File.basename(path, ".json")
        return if only ? only != name : fixture.key?("expect")

        fixture["domain"] ||= domain if domain
        fixture["expect"] = expectation_for(root, fixture, full: full)
        File.write(path, "#{JSON.pretty_generate(fixture)}\n")
        name
      end

      # @param root [String] the checkout
      # @return [Array<Array>] `[path, domain_to_add_or_nil, full_expect?]` for every seedable file
      def corpus_paths(root)
        semantics = Dir.glob(File.join(root, "spec/corpus/semantics", "*.json")).map { |p| [p, nil, false] }
        conformance = Dir.glob(File.join(root, "spec/corpus/rust_conformance", "*.json")).map { |p| [p, nil, true] }
        scripts = FULL_SCRIPTS.map { |file, domain| [File.join(root, file), domain, true] }
        semantics + conformance + scripts
      end

      # Replays the fixture's script against the Ruby runtime. Each refusal's `"kind"` is reduced
      # to its class name; `occurred_at` is stripped from events.
      #
      # @param root [String] the checkout the fixture's domain path is relative to
      # @param fixture [Hash] the parsed fixture: `domain` and `steps`
      # @param full [Boolean] also freeze queries, sagas, dry runs, reactions (conformance)
      # @return [Hash{String => Array}] its `"expect"` block: refusals, instances, events, and
      #   with `full` the {CONFORMANCE_KEYS}
      def expectation_for(root, fixture, full: false)
        result = Hecks::Fuzzing::Replay.call(File.join(root, fixture["domain"]), fixture["steps"])
        expect = {
          "refusals"  => kind_names(result[:refusals]),
          "instances" => roundtrip(result[:instances]),
          "events"    => without_timestamps(result[:events])
        }
        full ? expect.merge!(conformance_expectation(result)) : expect
      end

      # @api private
      def kind_names(refusals) = roundtrip(refusals).each { |r| r["kind"] = r["kind"]&.split("::")&.last }

      # @api private
      def without_timestamps(events) = roundtrip(events).each { |e| e.delete("occurred_at") }

      # @api private
      # @return [Hash{String => Array}] the queries, sagas, dry runs and reactions a run froze
      def conformance_expectation(result)
        # instances_at is Replay's per-query snapshot for the property harness, not an outcome.
        queries = roundtrip(result[:queries].map { |q| q.except(:instances_at) })
        { "queries" => queries }.merge(CONFORMANCE_KEYS.drop(1).to_h { |k| [k, roundtrip(result[k.to_sym])] })
      end

      # @api private
      # @return [Object] `value` as JSON would hand it back: String keys, plain collections
      def roundtrip(value) = JSON.parse(JSON.generate(value))

      # @param out [IO] where the report goes
      # @param seeded [Array<String>] the fixtures written
      # @return [void]
      def report(out, seeded)
        if seeded.empty?
          out.puts "nothing to seed — every fixture carries its expect (pass SEED=<name> to re-seed one deliberately)"
        else
          out.puts "seeded: #{seeded.join(", ")}"
          out.puts "review each expect against docs/semantics/bluebook-semantics.md before committing — " \
                   "it is the definition now"
        end
      end
    end
  end
end
