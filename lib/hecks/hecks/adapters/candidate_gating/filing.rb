# frozen_string_literal: true

require "hecks/runtime/dispatcher"
require "hecks/runtime/errors"
require_relative "../dispatching/work_items"
require_relative "causes"

module Hecks
  module Adapters
    class CandidateGating
      # The Work items a rejection files: one `red-<cause>` per failing cause of the red candidate,
      # through the booted registry's Tickets. A key already filed is reopened when its item was
      # closed and left alone when it is open. A registry with no Tickets files nothing.
      class Filing
        # @param registry [Runtime::Registry, nil] the booted registry the Work items are filed in
        # @param remote_main [String] the remote-tracking main local main was reset to
        def initialize(registry, remote_main:)
          @registry = registry
          @remote_main = remote_main
        end

        # @param candidate [Hash] the red candidate: `sha`, `ci_run`, `jobs`
        # @param branch [String] the branch that keeps its commits
        # @param carried [Rejection::Carried] what it carried
        # @return [Array<String>] the keys of the Work items filed, one per cause
        def file(candidate, branch, carried)
          return [] unless @registry&.bluebook("Tickets")

          causes = Causes.new(candidate["jobs"], lessons: Dispatching::WorkItems.new(@registry).lessons)
          causes.grouped.map do |cause, jobs|
            plan(causes.key(cause), title(candidate, cause), detail(candidate, jobs, branch, carried))
          end
        end

        private

        def title(candidate, cause) = "candidate #{candidate["sha"].to_s[0, 10]} red: #{cause} failed"

        def detail(candidate, jobs, branch, carried)
          "CI run #{candidate["ci_run"]} on the candidate failed in #{jobs.join(", ")}. The commits are kept on " \
            "#{branch} (#{carried.commits} commit(s); branches #{carried.branches.join(", ")}; authors " \
            "#{carried.authors.join(", ")}); local main was reset to #{@remote_main}. " \
            "Fix the cause on its branch, land it again and board a new candidate."
        end

        def plan(key, title, detail)
          dispatch("Tickets::Work.Plan", work: key, title: title, detail: detail)
          key
        rescue Runtime::AlreadyExists
          reopen(key)
        end

        def reopen(key)
          dispatch("Tickets::Work.Reopen", to: key)
          key
        rescue *Runtime::DOMAIN_REFUSALS
          key
        end

        def dispatch(verb, args) = Runtime::Dispatcher.new(@registry).dispatch_flat(verb, args)
      end
    end
  end
end
