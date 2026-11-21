# frozen_string_literal: true

require "etc"
require_relative "../load_guard"
require_relative "../pipeline_web/in_force"
require_relative "../pipeline_web/signalbox_marks"

module Hecks
  module Adapters
    module PipelineBoard
      # What the `Snapshot`'s newer readings are shaped from, each asked of the owner that holds it
      # and each answered as read or `{unknown: reason}`: Signalbox's posted signal and short mark
      # (the load chart's limit), the side deciding the fill, the red episodes, the outcome
      # measures, the ranked epics and the boarding hold.
      class ReadFacts
        # How many episodes of red main the snapshot carries.
        EPISODES = 5

        # @param registry [Runtime::Registry, nil] whose Tickets and Signalbox worlds are read
        # @param tickets [#recent_red_episodes, #measures, #epic_outcomes, #boarding_hold]
        # @param now [#call] answers the time
        def initialize(registry:, tickets:, now:)
          @registry = registry
          @tickets = tickets
          @now = now
        end

        # @param fill [Hash] the fill's report, or `{unknown: reason}`
        # @return [Hash] the facts {BoardReads.build} shapes
        def of(fill)
          { signal: asked { signal }, side: side, fill: fill, episodes: asked { @tickets.recent_red_episodes(EPISODES) },
            measures: asked { @tickets.measures }, epics: asked { @tickets.epic_outcomes },
            holds: asked { @tickets.boarding_hold } }
        end

        private

        def asked
          yield
        rescue StandardError => e
          { unknown: first_line(e.message) }
        end

        def first_line(text)
          head = text.lines.first
          head.to_s.strip
        end

        # @return [Hash] the posted signal's band, the load, Signalbox's short mark as a load and
        #   since when the machine has been short
        def signal
          reading = InForce.reading(@registry)
          posted = reading[:posted]
          { band: posted ? posted[:band].to_s : "dark", load: LoadGuard.reading.round(1), mark: mark(posted),
            since: LoadGuard.standing&.fetch(:since, nil).to_s[11, 5] }
        end

        # @return [Numeric, nil] Signalbox's short mark as a load across the posted cores
        def mark(posted)
          cores = (posted && posted[:cores]) || Etc.nprocessors
          found = SignalboxMarks.of(@registry, cores: cores).find { |row| row[:name] == "load_short_percent" }
          found&.dig(:beside, :load)
        end

        # @return [String] `admission` while admission.signalbox is on, else `dispatch`
        def side
          InForce::Rules.admitted?(InForce.reading(@registry)) ? "admission" : "dispatch"
        rescue StandardError
          "dispatch"
        end
      end
    end
  end
end
