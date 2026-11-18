# frozen_string_literal: true

require_relative "console_capture"
require_relative "main_integration/command_runner"
require_relative "github_branch_ci/gh_call"
require_relative "github_branch_ci/draft"
require_relative "github_branch_ci/run_wait"
require_relative "github_branch_ci/verdict"

module Hecks
  module Adapters
    # The `BranchCi` port's adapter for `EarlyCi.Request` and `Retry`: pushes a coder branch's head
    # as `ci/<branch>`, opens a draft pull request from it against main or reuses the open one,
    # waits a bounded time for the CI run of that head and answers the jobs that failed, and which
    # of them failed on the run of the branch's base too. It reads GitHub over REST only. It never
    # pushes main or a train, never forces and never skips the hook; the pass or fail is the
    # bluebook's, drawn from the jobs this answers.
    class GithubBranchCi
      # How long one request waits for the run, in minutes, under a coder's ten-minute call.
      MINUTES = 8

      # The prefix every pushed branch takes.
      PREFIX = "ci/"

      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; a command runner
        #   when nil. A spec replaces it with a fake git and GitHub.
        attr_accessor :runner

        # @return [#call, nil] takes the seconds to pause between reads; `Kernel.sleep` when nil
        attr_accessor :pause
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `minutes:` the wait, the default when absent
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @minutes = (settings || {})[:minutes] || MINUTES
      end

      # @param held [Hash] the `EarlyCi` record: `branch`, `sha` and `checkout`
      # @return [Hash{Symbol => Hash}] `sha`, `number`, `ci_run`, `failing` (the failed jobs'
      #   names, empty when none failed), `inherited` (those of them that failed on the branch's
      #   base too) and `report`
      # @raise [ConsoleCapture::Failure] when the push is refused, GitHub cannot be read, or the run
      #   has not ended within the wait
      def branch_ci(**held)
        branch, sha, checkout = %i[branch sha checkout].map { |key| plain(held[key]).to_s }
        checked(GhCall.new(runner, checkout), branch, sha)
      end

      private

      def checked(github, branch, sha)
        pushed_at = push(github, branch, sha)
        number = Draft.new(github).number("#{PREFIX}#{branch}", branch)
        run = RunWait.new(github, pause: self.class.pause, minutes: @minutes).completed(sha)
        Verdict.new(github, run, pushed_at).answer(sha, number)
      end

      def push(github, branch, sha)
        github.run!(["git", "push", "origin", "#{sha}:refs/heads/#{PREFIX}#{branch}"], "push of #{PREFIX}#{branch}")
        Time.now.utc
      end

      def runner = self.class.runner || MainIntegration::CommandRunner.new(bound: 600)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
