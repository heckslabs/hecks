# frozen_string_literal: true

require_relative "git"

module Hecks
  module Adapters
    # What a job read says about the session behind it: the agent the run named, the last words the
    # session wrote, and, for a coder whose job is done, the branch, commit and cleanliness of the
    # run's checkout as git reports them.
    #
    # It reads and judges nothing: whether the report hands the branch in, and whether the branch
    # and tree may be submitted, are the Coder bluebook's and the Hecks hecksagon's. Git is read
    # only for a coder's finished job, so polling a working session costs no git call. A checkout
    # git cannot read answers empty facts, which `Submission.Submit` refuses by name, so the job
    # read itself is never refused for it.
    class CoderJobFacts
      # @param git [Git] the adapter that runs `git`
      def initialize(git: Git.new)
        @git = git
      end

      # @param agent [String] the agent the run named, empty for the default
      # @param state [String] the state the job is in
      # @param report [String] the session's last words
      # @param checkout [String] the run's directory
      # @return [Hash{Symbol => Object}] `agent:` and `report:`, and for a done coder job
      #   `branch:`, `sha:` and `clean:`
      def call(agent:, state:, report:, checkout:)
        facts = { agent: agent.to_s, report: report.to_s }
        return facts unless agent.to_s == "coder" && state.to_s == "done"

        facts.merge(checkout_facts(checkout))
      end

      private

      def checkout_facts(checkout)
        return { branch: "", sha: "", clean: false } unless File.directory?(checkout.to_s)

        status = @git.capture("status", "--porcelain", chdir: checkout)
        { branch: read(checkout, "rev-parse", "--abbrev-ref", "HEAD"), sha: read(checkout, "rev-parse", "HEAD"),
          clean: status.ok? && status.out.strip.empty? }
      end

      # @return [String] what git printed, or empty when it refused
      def read(checkout, *)
        result = @git.capture(*, chdir: checkout)
        result.ok? ? result.out.strip : ""
      end
    end
  end
end
