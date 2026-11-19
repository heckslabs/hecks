# frozen_string_literal: true

require "json"
require_relative "metering/process_table"
require_relative "metering/machine_gauge"
require_relative "metering/session_role"
require_relative "metering/live_reads"

module Hecks
  module Adapters
    # The `Metering` port's adapter for Roundhouse's `Reading` (ADR 0222, phase 2): the per-session
    # meter and the machine's memory and load. A session is metered with its whole process tree, so
    # the MCP servers it started count against it. It reads `claude agents --json`, `ps`, `sysctl`
    # and `vm_stat` and the AgentRun ledger; it starts, stops and reaps nothing.
    class Metering
      SECONDS_PER_MINUTE = 60
      MS_PER_SECOND = 1000

      # @param registry [Runtime::Registry, nil] whose AgentRun ledger names each session's run
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins for the outside, each a callable: `listing:` (the listed
      #   sessions), `processes:` (the `ps` text), `machine:` (the `sysctl` and `vm_stat` reads),
      #   `runs:` (runs by session id), `activity:` (a session's last transcript time) and `now:`
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        live = LiveReads.new(registry)
        @listing = settings[:listing] || live.method(:listing)
        @processes = settings[:processes] || live.method(:processes)
        @machine = settings[:machine] || live.method(:machine)
        @runs = settings[:runs] || live.method(:runs)
        @activity = settings[:activity] || live.method(:activity)
        @now = settings[:now] || -> { Time.now }
      end

      # The `Sessions` query.
      #
      # @return [Hash{Symbol => String}] `text:` the per-session meter as JSON
      def sessions = { text: JSON.generate(rows) }

      # The `Machine` query.
      #
      # @return [Hash{Symbol => String}] `text:` the machine facts as JSON
      def machine = { text: JSON.generate(machine_facts) }

      # @return [Array<Hash>] each live session: `id`, `session`, `name`, `kind`, `state`, `status`,
      #   `role`, `works_as`, `item`, `run`, `memory_mb`, `cpu`, `processes`, `mcp_servers`,
      #   `started_at`, `last_activity`, `age_minutes` and `idle_minutes`
      def rows
        @rows ||= begin
          table = ProcessTable.new(@processes.call)
          runs = @runs.call
          Array(@listing.call).select { |entry| entry["pid"] && table.running?(entry["pid"]) }
                              .map { |entry| row(entry, table.tree(entry["pid"]), runs[entry["sessionId"].to_s]) }
        end
      end

      # @return [Hash] `capacity_mb`, `used_mb` (everything in use), `drawn_mb` (the pipeline's
      #   sessions), `person_mb` (sessions a person runs), `load` (hundredths), `cores` (performance
      #   cores), `sessions` and `taken_at`
      def machine_facts
        gauge = MachineGauge.new(@machine.call)
        person, pipeline = rows.partition { |row| row[:role] == "person" }
        { capacity_mb: gauge.capacity_mb, used_mb: gauge.used_mb, drawn_mb: pipeline.sum { |row| row[:memory_mb] },
          person_mb: person.sum { |row| row[:memory_mb] }, load: gauge.load, cores: gauge.cores, sessions: rows.size,
          taken_at: stamp(@now.call) }
      end

      private

      def row(entry, tree, run)
        started = Time.at(entry["startedAt"].to_i / MS_PER_SECOND).utc
        active = @activity.call(entry)
        { id: entry["id"].to_s, session: entry["sessionId"].to_s, name: entry["name"].to_s, kind: entry["kind"].to_s,
          state: entry["state"].to_s, status: entry["status"].to_s, role: SessionRole.of(entry, run),
          works_as: SessionRole.works_as(run), item: item_of(run), run: run ? run[:run].to_s : "", **tree.to_h,
          started_at: stamp(started), last_activity: active ? stamp(active) : "",
          age_minutes: minutes_since(started), idle_minutes: minutes_since(active || started) }
      end

      def item_of(run)
        return "" unless run

        work = run[:work].to_s
        work.empty? ? run[:run].to_s : work
      end

      def minutes_since(time) = ((@now.call - time) / SECONDS_PER_MINUTE).floor

      def stamp(time) = time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end
  end
end
