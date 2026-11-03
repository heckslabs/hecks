# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"

module Hecks
  module Adapters
    # Whether a repository gates main behind a candidate (ADR 0181). The switch a copy runs on is
    # the git configuration `hecks.candidateGate`, shared by every worktree of the repository and
    # read by the push train and the pre-push hook alike; when it is unset, the Hecks world's
    # `gate "Candidate", enabled:` row answers, and a world that declares none is off.
    class CandidateGate
      # The git configuration key the switch is kept under.
      CONFIG = "hecks.candidateGate"

      # The world verb the default comes from, and its key.
      VERB = "gate"
      KEY = :enabled

      # The remote branch the train pushes a candidate to.
      BRANCH = "candidate"

      # @param checkout [String] a directory inside the repository
      # @param registry [Runtime::Registry, nil] the booted registry whose world holds the default
      # @param git [Git] the adapter every git call goes through
      def initialize(checkout, registry: nil, git: Git.new)
        @checkout = checkout
        @registry = registry
        @git = git
      end

      # @return [Boolean] whether the gate is on for this repository
      def on?
        set = configured
        set.nil? ? default? : set
      end

      # @return [String] where the answer came from, for a report
      def source = configured.nil? ? "the Hecks world" : "git config #{CONFIG}"

      # Turns the gate on or off for the repository, in its git configuration.
      #
      # @param on [Boolean]
      # @return [Boolean] the setting written
      def switch!(on)
        result = @git.capture("config", CONFIG, on ? "true" : "false", chdir: @checkout)
        raise ConsoleCapture::Failure, "git config #{CONFIG} failed: #{result.err.strip}" unless result.ok?

        on
      end

      private

      # @return [Boolean, nil] the configured switch, nil when the repository sets none
      def configured
        result = @git.capture("config", "--type=bool", "--get", CONFIG, chdir: @checkout)
        return unless result.ok?

        result.out.strip == "true"
      end

      def default?
        declared = @registry&.world("Hecks")&.for_verb(VERB) || {}
        declared[KEY] == true
      end
    end
  end
end
