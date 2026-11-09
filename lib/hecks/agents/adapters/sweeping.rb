# frozen_string_literal: true

require "json"
require "tmpdir"
require "hecks/hecks/adapters/shell"
require "hecks/hecks/adapters/console_capture"
require_relative "sweeping/process_table"
require_relative "sweeping/spare_trace"
require_relative "sweeping/spare_plan"
require_relative "sweeping/footprint"
require_relative "sweeping/residue"
require_relative "sweeping/orphans"

module Hecks
  module Adapters
    # The `Machine` port's adapter for `Sweep`: finds what removed sessions left behind and clears
    # what it can trace to them. {#leftovers} lists and changes nothing; {#sweep} lists, then stops
    # the spare daemons the daemon's log traces to a removed session, deletes the temp files named
    # for one, and reports each worktree for `Landing.retire!` or as unlanded. It also stops the
    # launchers left running with no parent and the isolated pushes a rehearsal left behind
    # ({Orphans}), whichever session they trace to.
    #
    # A daemon that cannot be traced to a removed session is counted and left running; so is any
    # session still listed, whatever its state.
    class Sweeping
      SHORT_ID = /\A[0-9a-f]{8}\z/
      SEPARATORS = /[\s,]+/

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `shell:`, `log:` (the daemon log), `projects:`, `tmp:`, and
      #   `killer:` (called with a pid)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @shell = settings[:shell] || Shell.new
        @log = settings[:log] || File.join(Dir.home, ".claude", "daemon.log")
        @killer = settings[:killer] || ->(pid) { Process.kill("TERM", pid) }
        @tmps = settings[:tmp] ? [settings[:tmp]] : ["/tmp", Dir.tmpdir].uniq
        @residue = residue_for(settings)
      end

      # @param removed [Hash, String] the short ids of the removed sessions
      # @return [Hash{Symbol => String}] `text:` what a sweep would do; nothing is changed
      def leftovers(removed:)
        ids = ids_of(removed)
        lines = ["footprint  #{footprint.line}"] + plan_lines(ids) + residue_lines(ids, delete: false)
        { text: (lines + orphans.lines).join("\n") }
      end

      # @param removed [Hash, String] the short ids of the removed sessions
      # @return [Hash{Symbol => Hash}] `report:` each action taken, and the footprint before
      #   and after
      # @raise [ConsoleCapture::Failure] when the session list cannot be read
      def sweep(removed:, **)
        ids = ids_of(removed)
        before = footprint.line
        lines = stop_spares(ids) + residue_lines(ids, delete: true) + orphans.reap
        { report: { value: (["before  #{before}"] + lines + ["after   #{footprint.line}"]).join("\n") } }
      end

      private

      def residue_for(settings)
        projects = settings[:projects] || File.join(Dir.home, ".claude", "projects")
        Residue.new(shell: @shell, projects: projects, tmp: settings[:tmp] || "/tmp")
      end

      def stop_spares(ids)
        verdicts = plan(ids).verdicts
        stopped = verdicts.select(&:stop).each { |verdict| halt(verdict.host) }
        verdicts.map(&:line) + per_session(stopped) + ["untraced or kept  #{verdicts.count { |v| !v.stop }} spare host(s)"]
      end

      def halt(host)
        ([host] + table.below(host.pid)).each do |entry|
          @killer.call(entry.pid)
        rescue Errno::ESRCH
          next
        end
      end

      def per_session(stopped)
        stopped.group_by(&:session).map { |session, list| "spares stopped  #{session}  #{list.length}" }
      end

      def plan_lines(ids) = plan(ids).verdicts.map(&:line)

      def plan(ids)
        SparePlan.new(table: table, claims: SpareTrace.new(log: @log).claims, removed: ids, listed: listed)
      end

      def residue_lines(ids, delete:)
        ids.flat_map do |id|
          files = @residue.temp_files(id)
          files.each { |path| File.delete(path) } if delete
          [@residue.worktree(id)].compact + files.map { |path| "#{delete ? "deleted" : "would delete"}  #{path}" }
        end
      end

      def listed
        result = @shell.capture("claude", "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "claude could not list sessions: #{result.err.strip}" unless result.ok?

        JSON.parse(result.out).map { |entry| entry["id"].to_s }
      end

      def ids_of(removed)
        text = removed.is_a?(Hash) ? removed.transform_keys(&:to_s).fetch("value", "") : removed
        ids = text.to_s.split(SEPARATORS).grep(SHORT_ID)
        raise ConsoleCapture::Failure, "the sweep names no removed session" if ids.empty?

        ids
      end

      def table = (@table ||= ProcessTable.new(shell: @shell))

      def orphans = Orphans.new(table: table, killer: @killer, tmp: @tmps)

      def footprint = Footprint.new(shell: @shell, table: ProcessTable.new(shell: @shell))
    end
  end
end
