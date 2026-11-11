# frozen_string_literal: true

require_relative "console_capture"
require_relative "dispatching/settings"
require_relative "dispatching/work_items"
require_relative "dispatching/plan"
require_relative "dispatching/launcher"
require_relative "dispatching/in_process_runner"
require_relative "dispatching/filling"
require_relative "dispatching/fill_report"
require_relative "dispatching/lesson_traps"
require_relative "dispatching/settler"
require_relative "dispatching/last_roll"
require_relative "dispatching/pending"
require_relative "dispatching/planned_cache"
require_relative "dispatching/wake"
require_relative "dispatching/rolls"
require_relative "dispatching/rethinks"
require_relative "dispatching/launching"

module Hecks
  module Adapters
    # The `Dispatching` port's adapter for `Dispatch`: reads the Work queue and the machine, says
    # which
    # planned work items would start a session and why each other waits, and with `confirm` starts
    # them.
    #
    # It decides only what the Plan rules decide; whether a work item may start is still the
    # bluebook's
    # (the `WorkAreas` and `WorkLimits` ports refuse a start that clashes or goes over the cap). The
    # default is a dry run, which writes nothing.
    class Dispatching
      include Rolls
      include Launching

      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `load:`, `cpus:` and `runner:` stand in for the machine and the
      #   launcher
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
      end

      # Says which planned work items start now, and starts them when confirmed.
      #
      # @param held [Hash] the `Dispatch` record: `repo`, `budget_minutes`, `confirm`, and `only`,
      #   the key prefix the choice is held to
      # @return [Hash{Symbol => Hash}] `report:` the load; one line for each chosen work item, which
      #   says it would start or, when confirmed, that it started or why it went back to the plan;
      #   then the work items left waiting with the reason
      def choose(**held)
        confirmed = plain(held[:confirm]) == true
        Filling.during(confirmed) do
          settle_ended(held) if confirmed
          plan = plan_for(prefix(held), rolling: plain(held[:rolling]) == true)
          { report: { value: filling_lines(plan, held, confirmed).join("\n") } }
        end
      end

      # Says which planned work items would start now and why each other waits, without starting
      # any of them. It reads the same plan `choose` reads, so it never writes and never launches.
      #
      # @param held [Hash] the query's `repo`, `budget_minutes` and `only` (the key prefix)
      # @return [Hash{Symbol => String}] `text:` the report, one line per work item
      def preview(**held)
        { text: "#{report_lines(plan_for(prefix(held))).join("\n")}\n" }
      end

      # Checks every started session and settles the work item of each that ended: done finishes it.
      #
      # @param held [Hash] the `Dispatch` record: `repo`
      # @return [Hash{Symbol => Hash}] `report:` one line per work item settled
      def conclude(**held)
        lines = Settler.new(work_items, launcher_for(held), grace: machine.session_grace).call
        { report: { value: lines.empty? ? "nothing to settle" : lines.join("\n") } }
      end

      private

      # The load, each work item that starts or would, then each left waiting with its reason. A
      # confirmed filling counts what its launches did instead of saying what would start.
      def filling_lines(plan, held, confirmed)
        return report_lines(plan) unless confirmed

        note_stops(plan)
        report = FillReport.new(launch(plan, held))
        PlannedCache.clear!
        [header(plan, report.tally(plan.chosen.size))] + report.lines + plan.skipped.map { |skip| skipped_line(skip) }
      end

      # A confirmed filling finishes or yields the work items whose sessions ended before the plan
      # counts started rows, so the cap holds only live work, then frees the run keys of the work
      # items parked behind a run whose session is gone.
      def settle_ended(held)
        launcher = launcher_for(held)
        Settler.new(work_items, launcher, grace: machine.session_grace).call
        release_taken(launcher)
        PlannedCache.clear!
      end

      # A planned work item parked behind a run still recorded started is never launched, so the
      # retire the launcher makes on a refused dispatch cannot reach it: ask for the retire here.
      # `AgentRun.Retire` closes the run only when `claude agents` does not list its session.
      def release_taken(launcher)
        runs = work_items.runs
        planned("").each { |item| launcher.retire(item.key) if Parking.key_held?(item, runs) }
      end

      def work_items = @standins[:work_items] || WorkItems.new(@registry)

      def machine
        @machine ||= Settings.new(@registry, load: @standins[:load], cpus: @standins[:cpus], cap: @standins[:cap],
                                             boots: @standins[:boots])
      end

      # The launcher for the checkout the filling is for. A stand-in runner wins; otherwise the
      # steps dispatch on this registry when the checkout is the one this process stands in, and
      # run that checkout's own `exe/hecks` when it is another.
      def launcher_for(held)
        repo = plain(held[:repo])
        Launcher.new(repo, runner: @standins[:runner] || in_process_runner(repo))
      end

      def in_process_runner(repo) = InProcessRunner.fits?(@registry, repo) ? InProcessRunner.new(@registry) : nil

      def plan_for(only = "", rolling: false)
        Plan.new(planned(only, rolling: rolling), work_items.started, **limits)
      end

      # What bounds a filling: the machine's cap and load, what pauses every work item, and the
      # boot budget, which a red-* work item is exempt from. It only reads: a dry plan and the
      # board look at the queue through here too, and looking must not change what the clock's
      # next beat does.
      def limits
        gauge = machine
        { cap: gauge.cap, load: gauge.load, max_load: gauge.max_load, frozen: gauge.frozen, paused: gauge.paused,
          budget: gauge.boot_stop, exempt: WorkItems.method(:red?), **cached_reads(gauge) }
      end

      # The runs and the architect's reviews, each read once for the plan: the plan asks for them
      # on every planned item, and a read is a scan of the whole repository.
      def cached_reads(gauge)
        runs = once { work_items.runs }
        reviews = once { rethinks(gauge.rethink_limit) }
        { runs: runs, rethinks: ->(key) { reviews.call.stop_reason(key) } }
      end

      def once
        read = false
        value = nil
        -> { read ? value : (read = true) && (value = yield) }
      end

      # The key prefix a filling is held to; empty when none is named.
      def prefix(held) = plain(held[:only]).to_s

      # The load, then each work item that starts or would, then each left waiting with its reason.
      def report_lines(plan)
        [header(plan)] + plan.chosen.map { |item| chosen_line(item) } + waiting_lines(plan.skipped)
      end

      # The skips, with those the load alone caused said once: the reason, the count and the first
      # few that start when the load falls.
      def waiting_lines(skips)
        loaded, others = skips.partition { |skip| skip.reason.start_with?("skipped: load") }
        others.map { |skip| skipped_line(skip) } + load_line_for(loaded)
      end

      def load_line_for(loaded)
        return [] if loaded.empty?

        ["#{loaded.first.reason}: nothing starts; #{loaded.size} waiting, first #{loaded.first(3).map(&:key).join(", ")}"]
      end

      # The planned work items, held to those whose key starts with `only` when one is named, and
      # to those a roll may start when `rolling`.
      def planned(only, rolling: false)
        items = rolling ? work_items.rollable : work_items.planned
        items.select { |item| only.empty? || item.key.to_s.start_with?(only) }
      end

      def header_of(report) = report.partition("\n").first

      def header(plan, tally = "this fill would start #{plan.chosen.size}")
        "#{load_line}; started #{work_items.started.size} of cap #{machine.cap}; " \
          "#{tally}; frozen: #{frozen_line}; at #{ran_at}"
      end

      # The time the report was made, in UTC: a reader that finds the report later can tell how old
      # it is, which the record of a roll does not say.
      def ran_at = (@standins[:now]&.call || Time.now).utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      def load_line = "load #{machine.load.round(1)} (limit #{machine.max_load.round(1)}, #{machine.cpus} cpus)"

      def frozen_line = machine.frozen.empty? ? "none" : machine.frozen.join(", ")

      def chosen_line(item) = "would start #{item.key}: #{BriefText.new("outcome" => item.title).first_line}"

      def skipped_line(skip) = "#{skip.key} #{skip.reason}"

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
