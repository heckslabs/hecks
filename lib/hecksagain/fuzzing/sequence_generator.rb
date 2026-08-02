require "fileutils"
require "set"
require "tmpdir"
require_relative "invalid_value_generator"
require_relative "value_generator"
require_relative "sequence_generator/catalog"
require_relative "sequence_generator/picker"
require_relative "sequence_generator/step_builder"
require_relative "sequence_generator/outcome_tracker"

module Hecksagain
  module Fuzzing
    # A random-but-valid sequence of dispatches and queries, in the exact
    # `{name, note, steps}` shape `spec/parity/*.json` already uses — so it can
    # run through `bin/parity` completely unchanged. Boots a throwaway copy of
    # the domain and DISPATCHES each candidate step for real as it builds the
    # sequence (not just synthesizing plausible-looking JSON) : the only way to
    # know whether a step actually reached a new state, or which id an
    # auto-minted entity landed on, is to run it and watch what happened.
    #
    # Single-call fuzzing mostly misses the bugs this project has actually
    # found — they needed STATE first (a saga leg acting on a transfer that
    # already exists, a reference pointing at a customer already registered).
    # So this tracks what it has created as it goes, the same way
    # spec/banking_state_machine_spec.rb's hand-written generator does, and
    # weights later steps toward acting on what already exists.
    #
    # One concern per file beside this one: what the domain offers
    # (sequence_generator/catalog.rb), which step to try next (picker.rb),
    # how a step is built and dispatched (step_builder.rb), and what a
    # success taught us (outcome_tracker.rb).
    class SequenceGenerator
      include Catalog
      include Picker
      include StepBuilder
      include OutcomeTracker

      # Creating commands are always eligible ; weighting them heavier (not
      # exclusively — a domain with only one or two aggregates would starve
      # everything else) makes a sequence reach an actionable state sooner
      # instead of spending its early budget refusing "acts on nothing yet."
      CREATING_WEIGHT = 2

      # How often a payload is deliberately the wrong shape. Low, because a
      # refused step reaches no new state and a sequence of them is SILENT.
      MALFORMED_ARGUMENT_PROBABILITY = 0.12

      # How strongly an unexercised verb is preferred over one this sequence has
      # already dispatched. Random picking revisits the same handful of verbs and
      # leaves whole commands untouched for a whole run — which is the same
      # "reached no interesting state" problem the SILENT count reports, seen from
      # the generating end rather than the scoring end.
      UNEXERCISED_WEIGHT = 4

      def self.generate(domain_path, seed:, steps:)
        new(domain_path, seed: seed, steps: steps).call
      end

      def initialize(domain_path, seed:, steps:)
        @domain_path      = domain_path
        @seed             = seed
        @step_count       = steps
        @random           = Random.new(seed)
        @known_ids        = Hash.new { |h, k| h[k] = [] }
        @entity_known_ids = Hash.new { |h, k| h[k] = [] }
        @exercised        = Set.new
      end

      def call
        Dir.mktmpdir("hecksagain-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(@domain_path))
          FileUtils.cp_r(@domain_path, copy)
          # Real leftover data from ordinary use (bin/parity's own runs,
          # bin/console, whatever) lives under the example's data/ — copied
          # along with everything else. A generator that boots against it
          # starts from state its own known_ids tracking doesn't know about,
          # which is exactly the silent-contamination bug bin/parity's own
          # `run_domain` already guards against the same way : reset before
          # boot, every time.
          FileUtils.rm_rf(File.join(copy, "data"))
          runtime = Hecks.boot(copy)
          catalog = build_catalog(runtime)
          Array.new(@step_count) { attempt_step(runtime, catalog) }.compact
        end
      end

      private

      def attempt_step(runtime, catalog)
        entry = pick(catalog)
        return nil unless entry

        @exercised << entry[:verb]
        entry[:query] ? build_query_step(runtime, entry) : build_command_step(runtime, catalog, entry)
      end
    end
  end
end
