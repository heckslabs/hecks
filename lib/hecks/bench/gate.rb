require "open3"
require_relative "gate_workloads"
require_relative "stats"

module Hecks
  module Bench
    # The gate's rule (ADR 0188 point 4, docs/plans/kernel-thin-client.md): for each workload,
    # `rust:client` p50 is at most `ruby:memory` p50, and its p99 at most {P99_MARGIN} times the
    # in-process p99. A ratio read on one run, not microseconds, since load moves both together.
    # It also reads the kernel's boot cost against the start-up budget of `docs/cli-measures.md`.
    module Gate
      # How much slower than in-process the client's p99 may be.
      P99_MARGIN = 1.5

      # `docs/cli-measures.md`, "Startup budget": the ratio of a warm bare `hecks` to the machine's
      # floor when measured (2.8), and the ceiling the check holds it under (three times that).
      MEASURED_RATIO = 2.8
      CEILING_RATIO = 8.4

      # The floor: a fresh process that only loads bundler, five times, as the doc measures it.
      FLOOR_RUNS = 5

      # One workload's verdict: the two ratios, the figures behind them and whether both held.
      Verdict = Struct.new(:domain, :p50_ratio, :p99_ratio, :pass, keyword_init: true)

      module_function

      # @param results [Array<Hash>] `Suite` results, each with `:domain`, `:target` and `:median`
      # @return [Array<Verdict>] one per workload measured on both targets
      def verdicts(results)
        by_domain = results.group_by { |entry| entry[:domain] }
        by_domain.filter_map do |domain, entries|
          client = entries.find { |entry| entry[:target] == "rust:client" }
          memory = entries.find { |entry| entry[:target] == "ruby:memory" }
          verdict(domain, client, memory) if client && memory
        end
      end

      def verdict(domain, client, memory)
        focus = Workload.fetch(domain).focus
        p50 = ratio(client, memory, :p50_us, focus)
        p99 = ratio(client, memory, :p99_us, focus)
        Verdict.new(domain: domain, p50_ratio: p50, p99_ratio: p99, pass: p50 <= 1.0 && p99 <= P99_MARGIN)
      end

      def ratio(client, memory, key, focus)
        (figure(client, key, focus) / figure(memory, key, focus)).round(2)
      end

      def figure(entry, key, focus)
        focus ? entry[:median][:by_verb].fetch(focus).fetch(key) : entry[:median].fetch(key)
      end

      # The gate's whole reading of a run that measured `rust:client`.
      #
      # @param results [Array<Hash>] `Suite` results
      # @return [Hash] `:verdicts`, `:boot_cost` per workload, and the workloads still `:blocked`
      def reading(results)
        floor = floor_seconds
        boots = results.select { |entry| entry[:target] == "rust:client" }
                       .to_h { |entry| [entry[:domain], boot_cost(entry[:median][:boot_us], floor)] }
        { verdicts: verdicts(results).map(&:to_h), boot_cost: boots, blocked: GateWorkloads::BLOCKED }
      end

      # @return [Boolean] whether every verdict passed, and there was at least one
      def pass?(verdicts) = verdicts.any? && verdicts.all?(&:pass)

      # @return [Float] the median seconds of {FLOOR_RUNS} fresh processes that only load bundler
      def floor_seconds(runs: FLOOR_RUNS)
        Stats.median(Array.new(runs) { fresh_process_seconds })
      end

      def fresh_process_seconds
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Open3.capture2e(RbConfig.ruby, "-e", 'require "bundler/setup"')
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - began
      end

      # What the kernel's boot adds to the front of `exe/hecks`, as floors of the machine.
      #
      # @param boot_us [Float] the median boot, in microseconds
      # @param floor [Float] {floor_seconds}
      # @return [Hash] the added floors, the room the budget leaves, and whether it fits
      def boot_cost(boot_us, floor)
        added = (boot_us / 1_000_000.0 / floor).round(2)
        room = (CEILING_RATIO - MEASURED_RATIO).round(2)
        { boot_us: boot_us, floor_seconds: floor.round(4), added_ratio: added, room_ratio: room, fits: added <= room }
      end
    end
  end
end
