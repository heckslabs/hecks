# Hecks::Adapters::FixtureLlmAdapter
#
# [antibody-exempt: dream-study Phase 0h test seam — synthetic in-memory
#  swap for the :llm adapter so PMs that name :llm (Mind, Dream, Lucidity,
#  SleepCycle in Phase 4-7) can be specced in milliseconds instead of
#  blocking on real Claude latency. Retires when the production :llm
#  adapter ships and tests can adapt the real one with a mock layer
#  declared at the hecksagon level.]
#
# In-memory :llm adapter. Reads canned responses from a YAML file and
# returns deterministic content keyed by call signature. Drop-in for
# anywhere a :llm adapter would be wired during a test — the bluebook
# stays unchanged ; the loaded hecksagon flips :llm to :fixture.
#
# Keying conventions (one method per LLM use case, mapped to a stable
# tuple) :
#   - dream_pulse(cycle:, pulse:)         → keyed by [cycle, pulse]
#   - dream_interpretation(cycle_total:)  → keyed by cycle_total
#   - musing(source:, concept:)           → keyed by [source, concept]
#   - lucid_observation(cycle:, pulse:)   → keyed by [cycle, pulse] in
#                                           the dream_pulses tree where
#                                           is_lucid: true
#   - daydream(seed:)                     → keyed by seed string
#
# Missing keys raise Hecks::Adapters::FixtureLlmAdapter::MissingFixture
# — never silent-empty, never falls through to a live LLM.
#
# Two construction modes :
#   FixtureLlmAdapter.from_yaml(path)
#   FixtureLlmAdapter.new(data_hash)        # for inline fixtures in
#                                           # specs that don't want a
#                                           # YAML file
#
# Usage :
#   adapter = Hecks::Adapters::FixtureLlmAdapter.from_yaml(
#     "spec/fixtures/dream_responses.yaml"
#   )
#   r = adapter.dream_pulse(cycle: 1, pulse: 1)
#   r["text_fr"]  # => "des chiffres qui se déplient comme des fleurs..."
#   r["text_en"]  # => "numbers unfurling like flowers..."
#
require "yaml"

module Hecks
  module Adapters
    class FixtureLlmAdapter
      class MissingFixture < KeyError; end

      attr_reader :data, :source

      # Load fixtures from a YAML file. Returns a frozen adapter — the
      # adapter is read-only by design ; mutating the canned responses
      # mid-test would defeat the determinism the seam exists to
      # provide.
      def self.from_yaml(path)
        raw = File.read(path)
        new(YAML.safe_load(raw, permitted_classes: [Symbol]) || {}, source: path)
      end

      def initialize(data, source: "<inline>")
        @data = stringify(data)
        @source = source
        @data.freeze
      end

      # ── Lookup methods (one per LLM call site) ──────────────────────

      def dream_pulse(cycle:, pulse:)
        find_in_list("dream_pulses", cycle: cycle, pulse: pulse) do |row|
          row["text_fr"] && row["text_en"] && !row["is_lucid"]
        end
      end

      def lucid_observation(cycle:, pulse:)
        find_in_list("dream_pulses", cycle: cycle, pulse: pulse) do |row|
          row["is_lucid"] == true
        end
      end

      def dream_interpretation(cycle_total:)
        tree = data.fetch("dream_interpretation") do
          missing!("dream_interpretation", cycle_total: cycle_total)
        end
        key = "cycle_#{cycle_total}_lesson"
        tree.fetch(key) { missing!("dream_interpretation", cycle_total: cycle_total) }
      end

      def musing(source:, concept:)
        find_in_list("musing", source: source, concept: concept) do |row|
          row["idea_fr"] || row["idea_en"]
        end
      end

      def daydream(seed:)
        find_in_list("daydream", seed: seed) { |row| row["text_fr"] || row["text_en"] }
      end

      # Generic call-by-tuple — escape hatch for adapters that want to
      # use this fixture from production-like code (e.g. a future
      # :fixture branch of the production :llm adapter). Tests should
      # prefer the named methods above for clarity.
      def call(method_name, **kwargs)
        unless respond_to?(method_name) && !FixtureLlmAdapter
                .instance_method(method_name)
                .nil?
          missing!(method_name, **kwargs)
        end
        public_send(method_name, **kwargs)
      end

      private

      # Walk a list under +list_key+, return the first row whose tagged
      # fields match +match+ (after stringification) AND whose row
      # passes the optional yield-filter. Raises MissingFixture on
      # nothing found — the seam is "loud or silent never empty".
      def find_in_list(list_key, **match)
        rows = data.fetch(list_key) { missing!(list_key, **match) }
        rows = Array(rows)
        match_str = match.transform_keys(&:to_s).transform_values(&:to_s)
        hit = rows.find do |row|
          next false unless match_str.all? { |k, v| row[k].to_s == v }
          block_given? ? yield(row) : true
        end
        hit || missing!(list_key, **match)
      end

      def missing!(list_key, **match)
        raise MissingFixture,
              "no fixture for #{list_key} #{match.inspect} (source: #{source})"
      end

      # Recursively stringify keys + drop nils so YAML-loaded structures
      # behave like the inline-Hash construction path. Symbol values
      # remain Symbol because YAML.safe_load is told to permit them.
      def stringify(node)
        case node
        when Hash
          node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
        when Array
          node.map { |x| stringify(x) }
        else
          node
        end
      end
    end
  end
end
