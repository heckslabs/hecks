# frozen_string_literal: true

require "time"
require_relative "../branch_changes"
require_relative "../shell"

module Hecks
  module Adapters
    class StallWatching
      # The `shared-files` read of the machine: for the work items a look names, each one that is
      # a local branch, with its tip, when the tip was committed and the files it changes against
      # main. One `git for-each-ref` lists the tips and one diff per branch ({BranchChanges}) names
      # its files; it reads names only and changes nothing.
      class OpenBranches
        # One line per local branch: its name, its short tip and the tip's commit time.
        FORMAT = "%(refname:short)%09%(objectname:short)%09%(committerdate:iso-strict)"

        # @param repo [String] a checkout of the repository whose branches are read
        # @param shell [Shell] runs git
        def initialize(repo, shell: Shell.new)
          @repo = repo
          @shell = shell
        end

        # @param keys [Array<String>] the work items the tap shows open, each named as its branch
        # @return [Array<Hash>] `branch:`, `tip:`, `at:` (UTC, ISO 8601) and `files:` of each that
        #   is a local branch; none when git cannot list the branches
        def call(keys)
          changes = BranchChanges.new(@repo, shell: @shell)
          tips.select { |name, _, _| keys.include?(name) }.map do |name, tip, at|
            { branch: name, tip: tip, at: Time.iso8601(at).utc.iso8601, files: changes.of(name) }
          end
        end

        private

        def tips
          result = @shell.capture("git", "for-each-ref", "--format=#{FORMAT}", "refs/heads", chdir: @repo)
          result.ok? ? result.out.lines.map { |line| line.chomp.split("\t") } : []
        end
      end
    end
  end
end
