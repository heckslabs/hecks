# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      class Sentinel
        # The count of asks in a row at which the board held more than its share of a core: the
        # CPU seconds it spent between two asks over the wall seconds between them. An ask with no
        # CPU reading (the process is gone, `ps` failed) ends the run of hot asks, and a share of 0
        # never counts one, so the bound is off.
        class Heat
          # @param share [Numeric] the share of one core above which an ask is hot; 0 for none
          # @param asks [Integer] hot asks in a row that make the board hot
          def initialize(share:, asks:)
            @share = share.to_f
            @asks = asks.to_i
            @count = 0
            @last = nil
          end

          # @return [Heat] a heat that never counts an ask
          def self.off = new(share: 0, asks: 0)

          # @return [Integer] the hot asks in a row so far
          attr_reader :count

          # @return [Boolean] whether the bound is on, so an ask reads the board's CPU at all
          def on? = @share.positive?

          # Takes one ask's readings.
          # @param cpu [Numeric, nil] the board's CPU seconds now, nil when unread
          # @param wall [Numeric] monotonic seconds now
          # @return [Boolean] whether the board has been hot for `asks` asks in a row
          def hot?(cpu, wall)
            @count = above?(cpu, wall) ? @count + 1 : 0
            @last = cpu && [cpu.to_f, wall.to_f]
            on? && @count >= @asks
          end

          private

          def above?(cpu, wall)
            return false unless cpu && @last && on?

            spent = wall - @last.last
            spent.positive? && (cpu - @last.first) / spent > @share
          end
        end
      end
    end
  end
end
