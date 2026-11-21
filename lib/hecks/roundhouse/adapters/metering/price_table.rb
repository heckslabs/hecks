# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # The declared price table, data only: dollars per million tokens by model family, and what a
      # cache read and a cache write cost as a fraction of fresh input. A model not named here is
      # priced as Opus, the dearest, so an unknown model never reads as a saving.
      module PriceTable
        PER_MILLION = {
          "opus"   => { input: 15.0, output: 75.0 },
          "sonnet" => { input: 3.0, output: 15.0 },
          "haiku"  => { input: 1.0, output: 5.0 }
        }.freeze

        CACHE_READ_RATIO = 0.1
        CACHE_WRITE_RATIO = 1.25
        DEAREST = "opus"

        module_function

        # @param model [String] a model id such as `claude-sonnet-5-5`
        # @return [String] `opus`, `sonnet` or `haiku`; Opus when the id names none
        def family(model)
          PER_MILLION.keys.find { |name| model.to_s.include?(name) } || DEAREST
        end

        # @param model [String] a model id
        # @param usage [Hash] `input:`, `output:`, `cache_creation:` and `cache_read:` counts
        # @param as [String] the family to price it at; the model's own when nil
        # @return [Float] dollars
        def dollars(model, usage, as: nil)
          price = PER_MILLION.fetch(as || family(model))
          fresh = usage[:input] + (usage[:cache_creation] * CACHE_WRITE_RATIO) + (usage[:cache_read] * CACHE_READ_RATIO)
          ((fresh * price[:input]) + (usage[:output] * price[:output])) / 1_000_000.0
        end
      end
    end
  end
end
