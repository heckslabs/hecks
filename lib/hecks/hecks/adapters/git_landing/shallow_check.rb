# frozen_string_literal: true

require "tmpdir"
require_relative "../shell"
require_relative "../../../vocabulary"
require_relative "../../../indifferent_key"

module Hecks
  module Adapters
    class GitLanding
      # The landing's shallow checks: when a branch changes a path a `LandingTrigger` row names,
      # its tip is cloned at depth one into a temporary directory and the `landing` gate stage
      # runs there. A check that passes only on a full history (shallow history, constant clashes
      # between specs, git identity) refuses the landing by name before it reaches main.
      #
      # A branch that changes no such path runs nothing and costs no clone.
      class ShallowCheck
        # The command that runs the landing stage in a clone; the clone's `exe/hecks` runs it.
        GATE = %w[exe/hecks gate_run.gate! stage=landing --wait].freeze

        # What a completed gate run prints.
        COMPLETED = /"status":\s*"completed"/

        # The line of a stage's output that names what failed.
        FAILURE_LINE = /fail|error|red/i

        # Whether the world's `landing` setting leaves the checks on: absent, or any value but
        # `false`.
        #
        # @param setting [Hash, nil] the world's `landing` setting
        # @return [Boolean]
        def self.enabled_in?(setting)
          setting.nil? || IndifferentKey.read(setting, :shallow_checks) != false
        end

        # @param git [Git] the adapter every git call goes through
        # @param enabled [Boolean] whether the checks run at all
        # @param gate [#call, nil] answers the {Shell::Result} of the stage in a directory
        def initialize(git, enabled: true, gate: nil)
          @git = git
          @enabled = enabled
          @gate = gate || ->(dir) { Shell.new.capture(*GATE, chdir: dir) }
        end

        # Runs the stage on a depth-1 clone of `branch` when the checks are on and the branch
        # changes a triggered path.
        #
        # @param checkout [String] the worktree the branch is checked out in
        # @param branch [String] the branch whose tip is cloned
        # @param onto [String] the branch the change is measured against
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the branch and the first failure line of the stage
        def call(checkout, branch, onto)
          return unless @enabled && triggered?(checkout, branch, onto)

          in_clone(checkout, branch) { |dir| judge(branch, @gate.call(dir)) }
        end

        private

        def triggered?(checkout, branch, onto)
          paths = @git.capture("diff", "--name-only", "#{onto}...#{branch}", chdir: checkout).out.split("\n")
          patterns = Vocabulary.rows("LandingTrigger").map { |row| Regexp.new(row["pattern"]) }
          paths.any? { |path| patterns.any? { |pattern| pattern.match?(path) } }
        end

        def in_clone(checkout, branch)
          Dir.mktmpdir("landing-shallow-") do |dir|
            clone(checkout, branch, dir)
            yield File.join(dir, "tree")
          end
        end

        def clone(checkout, branch, dir)
          made = @git.capture("clone", "--depth", "1", "--branch", branch, "file://#{checkout}", "tree", chdir: dir)
          raise ConsoleCapture::Failure, "shallow check: could not clone #{branch}: #{made.out.strip}" unless made.ok?
        end

        def judge(branch, result)
          return if result.ok? && result.out.match?(COMPLETED)

          raise ConsoleCapture::Failure, "shallow check refused the landing of #{branch}: #{first_failure(result)}"
        end

        def first_failure(result)
          lines = result.out.lines
          (lines.find { |text| FAILURE_LINE.match?(text) } || lines.last.to_s).strip
        end
      end
    end
  end
end
