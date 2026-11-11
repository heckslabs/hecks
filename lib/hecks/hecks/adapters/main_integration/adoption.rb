# frozen_string_literal: true

require "securerandom"

module Hecks
  module Adapters
    class MainIntegration
      # Opens a run for a tip of local main that no run covers. A pull that rewrites a held tip
      # (a squash merge ahead of it) leaves the run keyed by the old commit superseded, and
      # nothing else names the new one. When no run is open, main is ahead of `origin/main`, and
      # `origin/main` carries none of the tip, it records the tip as landed on main
      # (`Landing.Adopt`), which starts the run the usual way; a tip some run already keys is
      # left alone, so it opens once.
      class Adoption
        # @param registry [Runtime::Registry] the booted registry whose runs are read
        def initialize(registry)
          @registry = registry
          @runs = Runs.new(registry)
        end

        # @return [Array<String>] one line for the run it opened; empty when no tip needs one
        def open_run
          last = @runs.all.last
          return [] if last.nil? || open?

          repository = Repository.new(last.checkout.empty? ? Dir.pwd : last.checkout)
          head = uncovered(repository)
          head ? record(head, repository.checkout) : []
        rescue ConsoleCapture::Failure
          []
        end

        private

        def uncovered(repository)
          repository.refresh
          head = repository.main
          head unless head == repository.remote_main || repository.carried_by(head) || @runs.find(head)
        end

        def record(head, checkout)
          report = "#{head[0, 10]} is ahead of origin/main with no run: opened one"
          args = { run: { value: SecureRandom.uuid }, branch: "main", landed: head, checkout: checkout, report: report }
          Runtime::Dispatcher.new(@registry).dispatch_flat("Hecks::Landing.Adopt", args)
          [report]
        end

        def open?
          @runs.all.any? { |run| MainIntegration::NEXT.key?(run.state) || Runs::IN_FLIGHT.include?(run.state) }
        end
      end
    end
  end
end
