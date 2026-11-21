# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # The declared price table, data only: dollars per million tokens for each model family, as
      # Anthropic publishes them (https://platform.claude.com/docs/en/about-claude/pricing, read
      # 2026-11-21). The rows carry the keys ADR 0220 gives a `model_price` row, so they can
      # move into the world without a rename. A cache read is a rate of its own per model, not
      # one ratio of input: Opus 5.5 and Sonnet 5.5 bill it at 0.05x, Haiku 5.5 at 0.1x. The
      # cache write is the 5-minute rate, because a usage row carries one cache-creation count.
      # Haiku 5.5 bills a request whose prompt (input, cache writes and cache reads) is over
      # 100,000 tokens at the `LONG_PROMPT` rates. A model not named here is priced as Opus, the
      # dearest, so an unknown model never reads as a saving.
      module PriceTable
        PER_MILLION = {
          "opus"   => { input_per_mtok: 4.0, output_per_mtok: 20.0, cache_write_per_mtok: 5.0, cache_read_per_mtok: 0.2 },
          "sonnet" => { input_per_mtok: 2.0, output_per_mtok: 10.0, cache_write_per_mtok: 2.5, cache_read_per_mtok: 0.1 },
          "haiku"  => { input_per_mtok: 0.1, output_per_mtok: 0.5, cache_write_per_mtok: 0.125, cache_read_per_mtok: 0.01 }
        }.freeze

        LONG_PROMPT = {
          "haiku" => {
            over:  100_000,
            rates: { input_per_mtok: 0.5, output_per_mtok: 2.5, cache_write_per_mtok: 0.625, cache_read_per_mtok: 0.05 }
          }
        }.freeze

        COUNTS = {
          input:          :input_per_mtok,
          output:         :output_per_mtok,
          cache_creation: :cache_write_per_mtok,
          cache_read:     :cache_read_per_mtok
        }.freeze

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
        # @return [Hash{Symbol => Float}] the `model_price` rates that apply to this one request
        def rates(model, usage, as: nil)
          name = as || family(model)
          long = LONG_PROMPT[name]
          long && prompt_tokens(usage) > long[:over] ? long[:rates] : PER_MILLION.fetch(name)
        end

        # @param model [String] a model id
        # @param usage [Hash] the counts, as for {rates}
        # @param as [String] the family to price it at; the model's own when nil
        # @return [Float] dollars
        def dollars(model, usage, as: nil)
          price = rates(model, usage, as: as)
          COUNTS.sum { |count, rate| usage[count] * price[rate] } / 1_000_000.0
        end

        # @param model [String] a model id
        # @param usage [Hash] the counts, as for {rates}
        # @return [Float] dollars its cache reads saved against paying fresh input
        def read_saving(model, usage)
          price = rates(model, usage)
          usage[:cache_read] * (price[:input_per_mtok] - price[:cache_read_per_mtok]) / 1_000_000.0
        end

        # @param model [String] a model id
        # @param usage [Hash] the counts, as for {rates}
        # @return [Float] the tokens the request's cache reads saved, at this model's own read rate
        def read_saving_tokens(model, usage)
          price = rates(model, usage)
          usage[:cache_read] * (1 - (price[:cache_read_per_mtok] / price[:input_per_mtok]))
        end

        # @param usage [Hash] the counts, as for {rates}
        # @return [Integer] the request's prompt length: input, cache writes and cache reads
        def prompt_tokens(usage)
          usage[:input] + usage[:cache_creation] + usage[:cache_read]
        end
      end
    end
  end
end
