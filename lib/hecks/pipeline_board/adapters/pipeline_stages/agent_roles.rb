# frozen_string_literal: true

require_relative "../../../hecks/adapters/claude_jobs"
require_relative "../../../hecks/adapters/architect_verdict"

module Hecks
  module Adapters
    module PipelineBoard
      # The agent roles the board pins at its top: each role's name and how many of its sessions are
      # live. The roles come from the Hecks world's `agent_roles` line. A session belongs to
      # a role when its name begins with the role's name.
      module AgentRoles
        module_function

        # @param registry [Runtime::Registry, nil]
        # @return [Array<String>] the declared role names, in declared order
        def declared(registry)
          names = world_settings(registry).fetch(:roles, "").to_s.split(",")
          names.map(&:strip).reject(&:empty?)
        end

        # @return [Hash] the `agent_roles` line of the Hecks world, or nothing when it has none
        def world_settings(registry)
          return {} unless registry

          world = registry.world("Hecks")
          world ? world.for_verb("agent_roles") : {}
        end

        # The events each role raises or answers, so its row can say what it last did. The names are
        # the events of the Agents bluebook, and of the Coder's `WorkSubmitted` for the coder.
        ROLE_EVENTS = {
          "planner"         => %w[PlanningRequested],
          "orchestrator"    => %w[WorkChecked WorkRouted DispatchAdviceRequested],
          "architect"       => %w[PlanReviewRequested PlanReviewed VerdictDelivered VerdictUndeliverable],
          "coder"           => %w[WorkSubmitted],
          "reviewer"        => %w[SubmissionReviewRequested SpecFailureJudged HandedToPerson
                                  VerdictDelivered VerdictUndeliverable],
          "release_manager" => %w[PromotionRecommended PromotionSettled]
        }.freeze

        # @param sessions [Array<Hash>, Hash] the board's sessions, or `{unknown:}`
        # @param names [Array<String>] the declared roles
        # @param events [Array<Hash>, Hash] the newest events first, or `{unknown:}`
        # @return [Array<Hash>, Hash] `name`, `live` and `last` for each role, or `{unknown:}`
        def of(sessions, names, events = [])
          return { unknown: "the sessions could not be read" } unless sessions.is_a?(Array)

          names.map { |name| card(name, sessions, events) }
        end

        # @return [Hash] one role's card: its live count, last event, the sessions working now and
        #   the work it has completed (finished sessions and events it handled, newest first)
        def card(name, sessions, events)
          mine = sessions.select { |s| s[:agent].to_s == name || s[:name].to_s.start_with?(name) }
          { name: name, last: last_of(name, events), handled: handled(name, events) }.merge(shown(mine))
        end

        # @return [Hash] the live count, the sessions working now and the three newest finished
        def shown(mine)
          working = mine.select { |s| %w[busy blocked].include?(s[:status]) }
          finished = mine.select { |s| s[:status] == "done" }.first(3)
          { live: working.size, working: working.map { |s| brief(s) }, completed: finished.map { |s| brief(s) } }
        end

        # @return [Hash] a session as the card shows it: its name, status and what it reported
        def brief(session)
          { id: session[:id], run: session[:run].to_s, name: session[:name], status: session[:status],
            detail: session[:detail].to_s.slice(0, 160) }
        end

        # @return [Array<Hash>] the five newest events the role handled, as `name`, `at` and `id`
        def handled(role, events)
          return [] unless events.is_a?(Array)

          mine = events.select { |found| ROLE_EVENTS.fetch(role, []).include?(found[:name]) }
          mine.first(5).map { |found| found.slice(:name, :at, :id) }
        end

        # @return [Hash, nil] the newest event the role handles, as `name`, `at` and `id`, or nil
        def last_of(role, events)
          return nil unless events.is_a?(Array)

          event = events.find { |found| ROLE_EVENTS.fetch(role, []).include?(found[:name]) }
          event && { name: event[:name], at: event[:at], id: event[:id] }
        end

        # The architect's plan reviews, taken from the architect's runs and what each session wrote
        # last. The runs persist in the run ledger; the review itself is not stored anywhere else.
        #
        # @param runs [Hash{String => Hash}, Hash] each run by session id, or `{unknown:}`
        # @param jobs [#closing] answers the tail of what a session wrote last
        # @return [Array<Hash>, Hash] each review's `work`, `verdict`, `findings`; or `{unknown:}`
        def reviews(runs, jobs = ClaudeJobs.new)
          return runs unless runs.is_a?(Hash) && !runs.key?(:unknown)

          architects = runs.select { |_, run| run[:agent] == "architect" }
          architects.map { |session, run| review(session, run, jobs.closing(session)) }
        end

        # @return [Hash] one review: the Work item it is for (the run's own, or its key when the run
        #   names none), its run key, its verdict and its findings
        def review(_session, run, closing)
          work = run[:work_item].to_s
          { work: work.empty? ? run[:run].to_s : work, run: run[:run].to_s, verdict: ArchitectVerdict.of(closing),
            findings: closing.strip[0, 2000] }
        end

        # The promotions the release manager recommends that the owner has not settled: each change
        # whose newest promotion event is a `PromotionRecommended`. The events come from the journal
        # and the event log, because the process that raised them has ended. The log keeps no
        # payload, so the reasons are blank.
        #
        # @param events [Array<Hash>, Hash] promotion events, newest first, or `{unknown:}`
        # @return [Array<Hash>, Hash] each recommendation's `change` and `reasons`, or `{unknown:}`
        def recommendations(events)
          return events unless events.is_a?(Array)

          open = events.uniq { |found| found[:id] }.select { |found| found[:name].to_s.end_with?("PromotionRecommended") }
          open.map { |found| { change: found[:id].to_s, reasons: "" } }.sort_by { |row| row[:change] }
        end
      end
    end
  end
end
