# frozen_string_literal: true

module Hecks
  module Adapters
    class CrewUsage
      # The arithmetic of one baseline window, over calls already read and deduplicated. A call is
      # `{ role:, usage: { input_tokens:, output_tokens:, cache_creation_input_tokens:,
      # cache_read_input_tokens: } }`. Tokens are all four counts added; the cache hit rate is
      # cache-read tokens over every input token (plain input, cache creation and cache read).
      class Calc
        # Minutes in every baseline window, so a later reading is compared like for like.
        WINDOW_MINUTES = 60
        COUNTS = %i[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].freeze

        # @param calls [Array<Hash>] the model calls inside the window
        # @param finished [Integer] the work items finished inside the window
        def initialize(calls, finished:)
          @calls = calls
          @finished = finished
        end

        # @return [Float] every token of every call, per minute of the window
        def tokens_per_minute = tokens(@calls) / WINDOW_MINUTES.to_f

        # @return [Float] the work items finished in the window, per hour
        def items_per_hour = @finished * 60.0 / WINDOW_MINUTES

        # @return [Float, nil] tokens per finished item, nil when none finished
        def tokens_per_item = @finished.zero? ? nil : tokens(@calls).to_f / @finished

        # @return [Float] cache-read tokens over all input tokens, 0 when there were none
        def cache_hit_rate = hit_rate(@calls)

        # @return [Hash{String => Hash}] per role: `:tokens_per_minute` and `:cache_hit_rate`
        def by_role
          @calls.group_by { |call| call[:role] }.sort.to_h do |role, calls|
            [role, { tokens_per_minute: tokens(calls) / WINDOW_MINUTES.to_f, cache_hit_rate: hit_rate(calls) }]
          end
        end

        private

        def tokens(calls) = calls.sum { |call| COUNTS.sum { |count| call[:usage][count].to_i } }

        def hit_rate(calls)
          read = sum(calls, :cache_read_input_tokens)
          all = read + sum(calls, :input_tokens) + sum(calls, :cache_creation_input_tokens)
          all.zero? ? 0.0 : read.to_f / all
        end

        def sum(calls, count) = calls.sum { |call| call[:usage][count].to_i }
      end
    end
  end
end
