# frozen_string_literal: true

require "json"
require_relative "console_capture"
require_relative "main_integration/command_runner"

module Hecks
  module Adapters
    # The trees CI already passed on: the head of every green `CI` run of a push to main or to the
    # candidate ref, read through `gh` and resolved to its tree in the repository. A commit whose
    # tree is among them needs no run of its own (ADR 0181): the same files were judged green once.
    class GreenTrees
      # The workflow whose runs count.
      WORKFLOW = "CI"

      # The branches a green run may have been on.
      BRANCHES = %w[main candidate].freeze

      # How many green runs of each branch are read.
      LIMIT = 30

      # @param git [Git] the adapter every git call goes through
      # @param checkout [String] a directory inside the repository
      # @param runner [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
      #   runner when nil. A spec replaces it with a fake GitHub.
      def initialize(git, checkout, runner: nil)
        @git = git
        @checkout = checkout
        @runner = runner || MainIntegration::CommandRunner.new
      end

      # @param commit [String] a commit in the repository
      # @return [String, nil] a green commit whose tree equals the commit's, nil when none does
      def match(commit)
        tree = tree_of(commit) or return
        green_heads.find { |head| tree_of(head) == tree }
      end

      private

      def green_heads = BRANCHES.flat_map { |branch| heads(branch) }

      def heads(branch)
        ok, output = @runner.call(["gh", "run", "list", "--workflow", WORKFLOW, "--branch", branch, "--event", "push",
                                   "--status", "success", "--json", "headSha", "--limit", LIMIT.to_s], chdir: @checkout)
        return [] unless ok

        JSON.parse(output).map { |run| run["headSha"].to_s }.reject(&:empty?)
      rescue JSON::ParserError
        []
      end

      # A commit the repository does not hold has no tree here.
      def tree_of(commit)
        done = @git.capture("rev-parse", "--verify", "--quiet", "#{commit}^{tree}", chdir: @checkout)
        done.ok? ? done.out.strip : nil
      end
    end
  end
end
