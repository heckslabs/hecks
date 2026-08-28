require "fileutils"
require "set"
require "tmpdir"
require_relative "isolated_boot"
require_relative "invalid_value_generator"
require_relative "value_generator"
require_relative "sequence_generator/catalog"
require_relative "sequence_generator/picker"
require_relative "sequence_generator/step_builder"
require_relative "sequence_generator/outcome_tracker"

module Hecks
  module Fuzzing
    # A random-but-valid sequence of dispatches and queries, in the exact
    # `{name, note, steps}` shape `spec/corpus/*.json` already uses — so a
    # generated sequence replays as a corpus member, completely unchanged.
    # Boots a throwaway copy of
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

      # HOW OFTEN AN OPTIONAL ARGUMENT IS SIMPLY NOT GIVEN — a fair coin,
      # because that is exactly what `optional:` means: present or absent,
      # both legal, neither the interesting case.
      #
      # This is NOT a malformation and must not be filed as one. `malform`
      # drops an argument too, but a dropped REQUIRED argument is refused,
      # a refusal writes no record, and bin/fuzz counts it SILENT — so the
      # one outcome worth reaching (a stored record carrying a null, then
      # QUERIED) was unreachable from that path by construction. Until
      # this existed no generated history contained a null at all, which
      # meant `query_answers_match_reference` — the differential that
      # diffs every native adapter against the reference interpreter — had
      # never once compared a nullable field. Four query bugs shipped in
      # exactly that blind spot (`ne:` with an empty string, array `in:`,
      # `ne:` against a null, `in` on a numeric field); the adapter
      # agreement gate had the identical hole and found a fourth bug the
      # hour it was closed.
      OPTIONAL_OMITTED_PROBABILITY = 0.5

      # How strongly an unexercised verb is preferred over one this sequence has
      # already dispatched. Random picking revisits the same handful of verbs and
      # leaves whole commands untouched for a whole run — which is the same
      # "reached no interesting state" problem the SILENT count reports, seen from
      # the generating end rather than the scoring end.
      UNEXERCISED_WEIGHT = 4

      def self.generate(domain_path, seed:, steps:, adapter: :memory)
        new(domain_path, seed: seed, steps: steps, adapter: adapter).call
      end

      # How many EVENTS the generated sequence actually produced — not
      # steps, not successful dispatches, but the sum of every Result#events
      # length across the run. This is the count bin/fuzz declares as the
      # script's own `expectations.events` claim: whatever was achieved
      # DURING generation becomes the claim a fresh replay of the same
      # script is held to. Zero means the sequence never
      # reached an interesting state — a fuzzer-effectiveness fact, not a
      # replay one.
      attr_reader :event_count

      def initialize(domain_path, seed:, steps:, adapter: :memory)
        @domain_path      = domain_path
        @seed             = seed
        @step_count       = steps
        @adapter          = adapter
        @random           = Random.new(seed)
        @known_ids        = Hash.new { |h, k| h[k] = [] }
        @entity_known_ids = Hash.new { |h, k| h[k] = [] }
        @exercised        = Set.new
        @event_count      = 0
      end

      def call
        # Real leftover data from ordinary use (bin/console, whatever) lives
        # under the example's data/ — a generator that boots against it
        # starts from state its own known_ids tracking doesn't know about.
        # IsolatedBoot resets that AND rebinds persistence to Memory, since
        # a Postgres-bound domain's real store lives outside the copied
        # directory entirely and `rm_rf`ing data/ alone cannot reach it —
        # see isolated_boot.rb's own header.
        IsolatedBoot.call(@domain_path, adapter: @adapter) do |copy|
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
        if entry[:query]      then build_query_step(runtime, entry)
        elsif entry[:model]   then build_read_model_step(runtime, entry)
        else                       build_command_step(runtime, catalog, entry)
        end
      end
    end
  end
end
