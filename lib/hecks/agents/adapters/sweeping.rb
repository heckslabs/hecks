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
require_relative "sweeping/worktrees"
require_relative "sweeping/orphans"

module Hecks
  module Adapters
    # The `Machine` port's adapter for `Sweep`: finds what removed sessions left behind and clears
    # what it can trace to them. {#leftovers} lists and changes nothing; {#sweep} lists, then stops
    # the spare daemons the daemon's log traces to a removed session and deletes the temp files
    # named for one. Every pass, with or without a removed session, it reads every worktree of the
    # repository ({Worktrees}) for `Landing.retire!` or as kept. It also stops the
    # launchers left running with no parent and the isolated pushes a rehearsal left behind
    # ({Orphans}), whichever session they trace to.
    #
    # A daemon that cannot be traced to a removed session is counted and left running; so is any
    # session still listed, whatever its state.
    class Sweeping
      SHORT_ID = /\A[0-9a-f]{8}\z/
      SEPARATORS = /[\s,]+/
      KEEPERS = %w[/.claude/hecks-train /switchyard-hecks].freeze
      TEMP_IDLE = 24 * 60 * 60

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `shell:`, `log:` (the daemon log), `tmp:`, `repo:` (a checkout of
      #   the repository, the working directory by default), `keepers:` (path fragments of
      #   worktrees always kept) and `killer:` (called with a pid)
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @shell = settings[:shell] || Shell.new
        @log = settings[:log] || File.join(Dir.home, ".claude", "daemon.log")
        @killer = settings[:killer] || ->(pid) { Process.kill("TERM", pid) }
        @repo = settings[:repo] || Dir.pwd
        @tmps = tmps_for(settings)
        @residue = Residue.new(tmp: settings[:tmp] || "/tmp")
        @worktrees = worktrees_for(settings)
      end

      # @param removed [Hash, String] the short ids of the removed sessions, possibly none
      # @param held [Hash, String] the branches an open item or a live run holds
      # @return [Hash{Symbol => String}] `text:` what a sweep would do; nothing is changed
      def leftovers(removed: "", held: "")
        ids = ids_of(removed)
        lines = ["footprint  #{footprint.line}"] + plan_lines(ids) + residue_lines(ids, delete: false)
        { text: (lines + worktree_lines(held, remove: false) + orphans.lines).join("\n") }
      end

      # @param removed [Hash, String] the short ids of the removed sessions, possibly none
      # @param held [Hash, String] the branches an open item or a live run holds
      # @return [Hash{Symbol => Hash}] `report:` each action taken, and the footprint before
      #   and after
      # @raise [ConsoleCapture::Failure] when the session list cannot be read
      def sweep(removed: "", held: "", **)
        ids = ids_of(removed)
        before = footprint.line
        lines = stop_spares(ids) + residue_lines(ids, delete: true) + worktree_lines(held, remove: true) + orphans.reap
        { report: { value: (["before  #{before}"] + lines + ["after   #{footprint.line}"]).join("\n") } }
      end

      private

      def tmps_for(settings) = settings[:tmp] ? [settings[:tmp]] : ["/tmp", Dir.tmpdir].uniq

      def worktrees_for(settings)
        temp = Worktrees::TempKind.new(roots: @tmps, idle: settings[:idle] || TEMP_IDLE)
        Worktrees.new(shell: @shell, repo: @repo, keepers: settings[:keepers] || KEEPERS, temp: temp)
      end

      def worktree_lines(held, remove:)
        reaper = Worktrees::TempReaper.new(shell: @shell, repo: @repo)
        reaper.apply(@worktrees.lines(held: names(held)), remove: remove)
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
          files.map { |path| "#{delete ? "deleted" : "would delete"}  #{path}" }
        end
      end

      def listed
        result = @shell.capture("claude", "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "claude could not list sessions: #{result.err.strip}" unless result.ok?

        JSON.parse(result.out).map { |entry| entry["id"].to_s }
      end

      def ids_of(removed)
        text = removed.is_a?(Hash) ? removed.transform_keys(&:to_s).fetch("value", "") : removed
        text.to_s.split(SEPARATORS).grep(SHORT_ID)
      end

      def names(held)
        text = held.is_a?(Hash) ? held.transform_keys(&:to_s).fetch("value", "") : held
        text.to_s.split(SEPARATORS).reject(&:empty?)
      end

      def table = (@table ||= ProcessTable.new(shell: @shell))

      def orphans = Orphans.new(table: table, killer: @killer, tmp: @tmps)

      def footprint = Footprint.new(shell: @shell, table: ProcessTable.new(shell: @shell))
    end
  end
end
