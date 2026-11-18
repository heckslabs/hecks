# frozen_string_literal: true

require "securerandom"
require "time"
require "hecks/runtime/dispatcher"
require "hecks/runtime/errors"
require "hecks/runtime/event_feed"

module Hecks
  module Adapters
    class MainIntegration
      # Parks the runs that stood in one stage past that stage's bound. The age is read from the
      # event tap, the durable record a restarted process still holds (the in-process event log is
      # empty then), and the bound from the Tickets world's `integration_bound`. This class reports
      # the two facts to `Integration.Stall`, whose given decides whether the run has stalled; a
      # run with no tap line for its stage is never taken for stale.
      class Stale
        # The world verb that carries each stage's bound, in minutes.
        VERB = "integration_bound"

        # Minutes a stage may stand when the world names no bound for it.
        DEFAULT_MINUTES = 60

        # The event that began each stage's wait, as the tap names it.
        SINCE = { "verifying" => "MainVerificationStarted", "reverifying" => "MainVerificationStarted",
                  "boarding" => "MainBoardingStarted", "pushed" => "MainPushed", "ci_running" => "MainPushed",
                  "merged" => "TrainMergeSeen" }.freeze

        # What each stage was waiting for, as a fact the reason names.
        WAITING_FOR = { "verifying" => "the quick gate and impacted specs in a clean copy",
                        "reverifying" => "the retried quick gate and impacted specs",
                        "boarding" => "the push train", "pushed" => "CI to start on the train pull request",
                        "ci_running" => "CI on the train pull request", "merged" => "CI on the merge commit" }.freeze

        class << self
          # Stands in for the tap's lines and the clock in a spec; no arguments restore the
          # machine's own.
          #
          # @param lines [#call, nil] answers the tap's event lines
          # @param clock [#call, nil] answers the current Time
          # @return [void]
          def stand_in(lines: nil, clock: nil)
            @lines = lines
            @clock = clock
          end

          # @return [#call] answers the tap's event lines
          def lines_source = @lines
          # @return [#call] answers the current Time
          def clock = @clock || -> { Time.now }
        end

        # @param registry [Runtime::Registry] the booted registry whose world and dispatch are used
        def initialize(registry)
          @registry = registry
        end

        # Dispatches `Integration.Stall` for each given run past its stage's bound.
        #
        # @param runs [Array<Runs::Run>] the runs to look at
        # @return [Array<String>] one line per run parked, or refused
        def park(runs)
          events = tap_lines
          runs.select { |run| SINCE.key?(run.state) }.filter_map { |run| stall(run, events) }
        end

        private

        def stall(run, events)
          age = age_of(run, events)
          bound = bound_of(run.state)
          return nil if age.nil? || age < bound

          record(run, age, bound)
        end

        def age_of(run, events)
          at = began(run, events)
          at && ((self.class.clock.call - at) / 60).floor
        end

        def began(run, events)
          mine = events.select { |e| e["event"] == SINCE[run.state] && e.dig("links", "landed") == run.landed }
          mine.map { |e| Time.parse(e["at"]) }.max
        end

        def bound_of(state) = Integer(@registry.world("Tickets")&.for_verb(VERB).to_h[state.to_sym] || DEFAULT_MINUTES)

        def record(run, age, bound)
          reason = "stalled in #{run.state} for #{age} min (bound #{bound}): waiting for #{WAITING_FOR[run.state]}"
          args = { run: SecureRandom.uuid, landed: run.landed, age: age, bound: bound, refusal: reason }
          Runtime::Dispatcher.new(@registry).dispatch_flat("Hecks::Integration.Stall", args)
          "#{run.short} #{run.state} -> needs_human: #{reason}"
        rescue *Runtime::DOMAIN_REFUSALS, StandardError => e
          "#{run.short} #{run.state}: Stall refused: #{e.message}"
        end

        def tap_lines
          return self.class.lines_source.call if self.class.lines_source

          path = tap_path
          path ? Runtime::EventFeed.new(path: path).read(since: 0, limit: 10**9)[:events] : []
        end

        def tap_path
          settings = @registry.world("Hecks")&.for_verb(Runtime::EventTap::VERB).to_h
          Runtime::EventTap.path_for(settings, Assembly.event_tap_override)
        end
      end
    end
  end
end
