# frozen_string_literal: true

require "hecks/hecks/adapters/shell"
require "hecks/hecks/adapters/claude_cleaning/worktree_check"
require_relative "worktrees/listing"
require_relative "worktrees/temp_kind"
require_relative "worktrees/temp_reaper"

module Hecks
  module Adapters
    class Sweeping
      # Every linked worktree of the repository, read as facts and named by kind: `retire` (clean,
      # its work on main, to be retired with `Landing.retire!`), `dirty` (uncommitted files, never
      # touched),
      # `item` (unlanded commits whose branch is held by an open item or a live run), `file`
      # (unlanded commits nothing holds, with its commits and diffstat), `nested` (holds another
      # worktree, judged after it), `keeper`, `detached` and `temp` (branchless, clean, absorbed,
      # idle, under a temp root: {TempReaper} removes it). It reads and removes nothing itself.
      class Worktrees
        KINDS = %w[retire dirty item file nested keeper detached temp].freeze

        # @param shell [Shell] runs `git`
        # @param repo [String] any checkout of the repository
        # @param keepers [Array<String>] path fragments of worktrees that are always kept
        # @param temp [TempKind, nil] says which branchless worktrees are idle temp ones
        def initialize(shell:, repo:, keepers: [], temp: nil)
          @temp = temp
          @shell = shell
          @check = ClaudeCleaning::WorktreeCheck.new(shell: shell)
          @listing = Listing.new(shell: shell, repo: repo)
          @repo = repo
          @keepers = keepers
        end

        # @param held [Array<String>] branches an open item or a live run holds
        # @return [Array<String>] one line per worktree, innermost first, then a count per kind
        def lines(held: [])
          entries = @listing.linked.sort_by { |entry| -entry.path.count("/") }
          out = entries.map { |entry| line(entry, entries, held) }
          out + (out.empty? ? [] : [counts(out)])
        end

        private

        def line(entry, all, held)
          return "keeper  #{entry.path}" if @keepers.any? { |fragment| entry.path.include?(fragment) }

          inner = all.count { |other| other != entry && other.path.start_with?("#{entry.path}/") }
          return "nested  #{entry.path}  holds #{inner} inner worktree(s)" if inner.positive?

          judged(entry, held)
        end

        def judged(entry, held)
          dirty = @check.uncommitted(entry.path)
          return "dirty  #{entry.path}  #{dirty} uncommitted file(s)" if dirty.positive?
          return unlanded(entry, held) unless absorbed?(entry)
          return branchless(entry) unless entry.branch

          "retire  branch=#{entry.branch}  checkout=#{entry.path}"
        end

        def branchless(entry)
          return "temp  #{entry.path}  absorbed, idle, no branch" if @temp&.temp?(entry.path)

          "detached  #{entry.path}  absorbed, no branch to retire"
        end

        def unlanded(entry, held)
          return "detached  #{entry.path}  holds commits main lacks" unless entry.branch
          return "item  branch=#{entry.branch}  checkout=#{entry.path}" if held.include?(entry.branch)

          "file  branch=#{entry.branch}  checkout=#{entry.path}  #{evidence(entry)}"
        end

        def absorbed?(entry)
          return true if git("merge-base", "--is-ancestor", entry.tip, "main").ok?

          cherry = git("cherry", "main", entry.tip)
          cherry.ok? && cherry.out.lines.none? { |line| line.start_with?("+") }
        end

        def evidence(entry)
          "commits: #{commit_summary(entry)}  diffstat: #{git("diff", "--shortstat", "main...#{entry.tip}").out.strip}"
        end

        def commit_summary(entry)
          oneline = git("log", "--oneline", "main..#{entry.tip}").out
          oneline.lines.map(&:strip).join(" | ")
        end

        def git(*) = @shell.capture("git", "-C", @repo, *)

        def counts(out)
          tally = out.map { |line| line.split.first }.tally
          "worktrees  #{KINDS.map { |kind| "#{kind}=#{tally.fetch(kind, 0)}" }.join(" ")}"
        end
      end
    end
  end
end
