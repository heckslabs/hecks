# frozen_string_literal: true

require_relative "machine_profiling/rows"
require_relative "machine_profiling/derivation"
require_relative "machine_profiling/reading"

module Hecks
  module Adapters
    # The `Deriving` port's adapter for `Profile`: reads this machine's facts and answers the
    # capacity settings the bluebook's `Formula` and `Bound` rows derive from them. It uses only
    # the standard library, so a launcher that boots nothing can ask. A setting the owner declares
    # in a world file is the override, and the consumers read it first.
    class MachineProfiling
      # @param setting [String] `residents`, `heavy_jobs`, `spec_workers`, `load_low` or `load_high`
      # @param profile [Hash, nil] the profile's measures; this machine's, read once, when absent
      # @param default [Numeric, nil] what to answer when it cannot be derived
      # @param corrections [Hash{String => Float}] kept `Turn` factors of this machine by setting
      # @return [Numeric, nil] the derived value, the default when it cannot be derived
      def self.of(setting, default = nil, profile: nil, corrections: {})
        Derivation.value(setting, profile || standing, Rows.from_file, corrections) || default
      rescue StandardError
        default
      end

      # @return [Hash] this machine's measures, read once per process
      def self.standing = (@standing ||= Reading.new.facts)

      # @param aggregate [Bluebook::Aggregate, nil] `Profile`, whose rows are read
      # @param profile [Hash, nil] the measures to derive from, this machine's when absent
      def initialize(aggregate: nil, profile: nil, **)
        @aggregate = aggregate
        @profile = profile
      end

      # @param held [Hash] the query's `setting`
      # @return [Hash{Symbol => String}] `text:` the setting and its derived value
      def derive(**held)
        setting = held[:setting].is_a?(Hash) ? held[:setting][:value] : held[:setting]
        rows = @aggregate ? Rows.of(@aggregate) : Rows.from_file
        { text: "#{setting}: #{Derivation.value(setting, @profile || self.class.standing, rows)}" }
      end
    end
  end
end
