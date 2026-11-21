# frozen_string_literal: true

require "json"
require_relative "metering/process_table"
require_relative "metering/machine_gauge"
require_relative "metering/session_role"
require_relative "metering/session_runs"
require_relative "metering/live_reads"
require_relative "metering/ended_rows"
require_relative "metering/copy_reads"
require_relative "metering/token_transcripts"
require_relative "metering/token_report"

module Hecks
  module Adapters
    # The `Metering` port's adapter for Roundhouse's `Reading` (ADR 0222, phase 2): the per-session
    # meter and the machine's memory and load. A session is metered with its whole process tree, so
    # the MCP servers it started count against it. It reads `claude agents --json`, `ps`, `sysctl`
    # and `vm_stat` and the AgentRun ledger; it starts, stops and reaps nothing.
    class Metering
      SECONDS_PER_MINUTE = 60
      MS_PER_SECOND = 1000

      # What `claude agents` lists of a session, each as text.
      LISTED = { id: "id", session: "sessionId", name: "name", kind: "kind", state: "state", status: "status" }.freeze

      # @param registry [Runtime::Registry, nil] whose AgentRun ledger names each session's run
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins for the outside, each a callable: `listing:` (the listed
      #   sessions), `processes:` (the `ps` text), `machine:` (the `sysctl` and `vm_stat` reads),
      #   `runs:` (runs by session id), `usage:` (the token
      #   usage rows), `activity:` (a session's last transcript time), `copies:` (the checkout's
      #   worktrees, as {CopyReads#call} answers) and `now:`
      # @param root [String, nil] the checkout whose copies are read; the working directory when nil
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        live = LiveReads.new(registry)
        @listing, @processes, @machine, @runs, @activity =
          %i[listing processes machine runs activity].map { |read| settings[read] || live.method(read) }
        @usage = settings[:usage] || TokenTranscripts.new
        @now = settings[:now] || -> { Time.now }
        @copies = settings[:copies] || CopyReads.new(root || Dir.pwd, now: @now)
      end

      # The `Sessions` query.
      #
      # @return [Hash{Symbol => String}] `text:` the per-session meter as JSON
      def sessions = { text: JSON.generate(rows) }

      # The `Tokens` query: tokens used and saved, rolled up from the transcripts' usage records.
      #
      # @return [Hash{Symbol => String}] `text:` the {TokenReport} facts as JSON
      def tokens = { text: JSON.generate(TokenReport.new(Array(@usage.call), @runs.call).facts) }

      # The `Machine` query.
      #
      # @return [Hash{Symbol => String}] `text:` the machine facts as JSON
      def machine = { text: JSON.generate(machine_facts) }

      # The `Ended` query (ADR 0222, phase 3, reaping).
      #
      # @return [Hash{Symbol => String}] `text:` the ended sessions and the copies as JSON
      def ended = { text: JSON.generate(ended_facts) }

      # What Signalbox rules a reap on: each finished or stale session ({EndedRows}) and each copy
      # of the checkout ({CopyReads}), a copy marked `held` while a live session works inside it.
      #
      # @return [Hash] `sessions:` and `copies:`, each an array of rows
      def ended_facts
        table = ProcessTable.new(@processes.call)
        listing = Array(@listing.call)
        sessions = EndedRows.new(table: table, runs: @runs.call, activity: @activity, now: @now).rows(listing)
        { sessions: sessions, copies: held(@copies.call, live(table, listing).map { |entry| entry["cwd"].to_s }) }
      end

      # The `Load` query.
      #
      # @return [Hash{Symbol => String}] `text:` the load facts as JSON
      def load = { text: JSON.generate(load_facts) }

      # The machine's 1-minute load and the cores it is read against, read without the session
      # rows, so a reader of load alone lists no session and reads no process table.
      #
      # @return [Hash] `load` (hundredths; nil when the load could not be read, never a calm 0),
      #   `cores` (performance cores) and `taken_at`
      def load_facts
        reads = @machine.call
        gauge = MachineGauge.new(reads)
        { load: reads[:loadavg].to_s.strip.empty? ? nil : gauge.load, cores: gauge.cores, taken_at: stamp(@now.call) }
      end

      # @return [Array<Hash>] each live session: `id`, `session`, `name`, `kind`, `state`, `status`,
      #   `role`, `works_as`, `item`, `run`, `memory_mb`, `cpu`, `processes`, `mcp_servers`,
      #   `started_at`, `last_activity`, `age_minutes` and `idle_minutes`
      def rows
        @rows ||= begin
          table = ProcessTable.new(@processes.call)
          runs = @runs.call
          live(table).map { |entry| row(entry, table.tree(entry["pid"]), SessionRuns.of(runs, entry)) }
        end
      end

      # @return [Hash] `capacity_mb`, `used_mb` (everything in use), `drawn_mb` (the pipeline's
      #   sessions), `person_mb` (sessions a person runs), `coder_draw_mb` (the median live coder's
      #   memory, 0 when none is metered), `load` (hundredths), `cores` (performance cores),
      #   `memory_pressure_level` (the kernel's, 0 unread), `sessions` and `taken_at`
      def machine_facts
        gauge = MachineGauge.new(@machine.call)
        { capacity_mb: gauge.capacity_mb, used_mb: gauge.used_mb, **draws, coder_draw_mb: median_draw("coder"),
          load: gauge.load, cores: gauge.cores, memory_pressure_level: gauge.memory_pressure_level,
          sessions: rows.size, taken_at: stamp(@now.call) }
      end

      private

      # The listed sessions whose own process is still running.
      def live(table, listing = @listing.call)
        Array(listing).select { |entry| entry["pid"] && table.running?(entry["pid"]) }
      end

      def held(copies, cwds)
        copies.map { |copy| { **copy, held: cwds.any? { |cwd| inside?(cwd, copy[:path]) } ? "yes" : "no" } }
      end

      def inside?(cwd, path) = cwd == path || cwd.start_with?("#{path}/")

      # `drawn_mb`, what the pipeline's sessions draw, and `person_mb`, what a person's own do.
      def draws
        person, pipeline = rows.partition { |row| row[:role] == "person" }
        { drawn_mb: pipeline.sum { |row| row[:memory_mb] }, person_mb: person.sum { |row| row[:memory_mb] } }
      end

      # The median memory of the live sessions of one role, the middle two averaged; 0 when none.
      def median_draw(role)
        drawn = rows.filter_map { |row| row[:memory_mb] if row[:role] == role }.sort
        drawn.empty? ? 0 : (drawn.values_at((drawn.size - 1) / 2, drawn.size / 2).sum / 2.0).round
      end

      def row(entry, tree, run)
        { **LISTED.transform_values { |field| entry[field].to_s }, **of_run(entry, run), **tree.to_h, **times(entry) }
      end

      # The role, part, Work item and run a session's AgentRun names.
      def of_run(entry, run)
        { role: SessionRole.of(entry, run), works_as: SessionRole.works_as(run), item: item_of(run),
          run: run ? run[:run].to_s : "" }
      end

      # When the session started and last did something, and the minutes since each.
      def times(entry)
        started = Time.at(entry["startedAt"].to_i / MS_PER_SECOND).utc
        active = @activity.call(entry)
        { started_at: stamp(started), last_activity: active ? stamp(active) : "",
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
