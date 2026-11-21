# frozen_string_literal: true

module Hecks
  module Adapters
    class Looking
      # The marks and draws the Signalbox world sets (`signalbox.world`): the memory target, floor
      # and gap, the load marks, how long a reading stays current, the person's reserve and a
      # coder's and a gate's expected draw. It reads them as the world declares them and compares
      # none.
      class Marks
        # The world declares a setting line that cannot be read. The beat is refused with this,
        # rather than judged on starting values the world did not set.
        class Unread < StandardError; end

        # The world's settings when no world is loaded: the 2026-11-19 starting values, with the
        # load marks in percent of every core (tight 18 and short 30 on 12 cores).
        PRESSURE = { reserve_mb: 8_192, target_mb: 6_144, floor_mb: 3_072, gap_mb: 2_048, stale_after_seconds: 120,
                     load_tight_percent: 150, load_short_percent: 250, load_gap_percent: 25 }.freeze
        DRAWS = { coder_mb: 1_536, gate_mb: 2_560 }.freeze

        # @param registry [Runtime::Registry, nil] whose Signalbox world is read
        # @raise [Unread] when a line the world declares cannot be read
        def initialize(registry)
          world = registry&.world("Signalbox")
          @pressure = PRESSURE.merge(setting(world, "pressure"))
          @draws = DRAWS.merge(setting(world, "draws"))
        end

        # @return [Hash] `reserve:`, `target:`, `floor:`, `gap:`, `stale_after:`, `load_tight:`,
        #   `load_short:`, `load_gap:`, `coder_draw:` and `gate_draw:`
        def facts
          { reserve: @pressure[:reserve_mb], target: @pressure[:target_mb], floor: @pressure[:floor_mb],
            gap: @pressure[:gap_mb], stale_after: @pressure[:stale_after_seconds],
            load_tight: @pressure[:load_tight_percent], load_short: @pressure[:load_short_percent],
            load_gap: @pressure[:load_gap_percent], coder_draw: @draws[:coder_mb],
            gate_draw: @draws[:gate_mb] }
        end

        private

        # A world or line that is not declared keeps the starting values; one that is declared and
        # cannot be read raises {Unread}.
        def setting(world, verb)
          found = world&.for_verb(verb)
          return {} if found.nil?
          raise Unread, "the Signalbox world's #{verb} line is not a set of marks" unless found.is_a?(Hash)

          found.transform_keys(&:to_sym)
        rescue Unread
          raise
        rescue StandardError => e
          raise Unread, "the Signalbox world's #{verb} line could not be read: #{e.message}"
        end
      end
    end
  end
end
