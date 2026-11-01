# frozen_string_literal: true

require_relative "../area_overlap"

module Hecks
  module Adapters
    class Dispatching
      # Which planned rows start a session now, and why each of the others waits. It decides from the
      # rows it is given and starts nothing.
      #
      # A planned row waits when it sits in a frozen area, when its area overlaps a started row's or an
      # earlier chosen row's (by {AreaOverlap}), or when the machine is loaded or the cap is reached,
      # which also hold back every row after it.
      class Plan
        # A row, as {Rows} reads it.
        Row = Struct.new(:key, :title, :detail, :area, keyword_init: true)

        # What a name is compared without, so `quality_control` and `QualityControl` meet.
        NOT_ALNUM = /[^a-z0-9]/

        # A row left waiting, and the reason.
        Skip = Struct.new(:key, :reason)

        # @return [Array<Row>] the rows to start, in plan order
        attr_reader :chosen

        # @return [Array<Skip>] the rows left waiting, in plan order
        attr_reader :skipped

        # @param planned [Array<Row>] the planned rows, in plan order
        # @param started [Array<Row>] the started rows
        # @param limits [Hash] `cap:` (Integer), `load:` and `max_load:` (Float), `frozen:` (Array)
        def initialize(planned, started, **limits)
          @started = started
          @limits = limits
          @chosen = []
          @skipped = []
          planned.each { |row| consider(row) }
        end

        # @return [Array<Row>] the started rows and the chosen ones: whose areas are not to be edited
        def holders = @started + @chosen

        private

        def consider(row)
          reason = stop_reason || frozen_reason(row) || overlap_reason(row)
          reason ? @skipped << Skip.new(row.key, reason) : @chosen << row
        end

        def stop_reason = overloaded || capped

        def overloaded
          return unless @limits[:load] > @limits[:max_load]

          "skipped: load #{@limits[:load].round(1)} > #{@limits[:max_load].round(1)}"
        end

        def capped
          return unless holders.size >= @limits[:cap]

          "skipped: cap #{@limits[:cap]} reached (#{holders.size} started or chosen)"
        end

        def frozen_reason(row)
          hit = @limits[:frozen].find { |name| row.area.any? { |word| squash(word).include?(squash(name)) } }
          "skipped: frozen (#{hit})" if hit
        end

        def overlap_reason(row)
          holders.each do |other|
            pair = AreaOverlap.first_overlap(row.area, other.area)
            return "skipped: #{pair[0]} overlaps #{other.key} at #{pair[1]}" if pair
          end
          nil
        end

        def squash(text) = text.to_s.downcase.gsub(NOT_ALNUM, "")
      end
    end
  end
end
