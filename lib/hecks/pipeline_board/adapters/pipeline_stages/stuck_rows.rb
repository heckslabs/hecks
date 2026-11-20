# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # What the pipeline is stuck on, as the bluebook's `StuckItem` rows: a red main, each
      # session blocked on a person, and each live session the `Session idle` rows call stalled.
      module StuckRows
        RED = "Red flag"

        module_function

        # @param state [Hash] the board's state, whose `stages` hold the red flag's row while one
        #   stands
        # @param sessions [Array<Hash>] the sessions, each marked by who it waits on
        # @return [Array<Hash>] the `StuckItem` rows, the red main first
        def of(state, sessions)
          red(state[:stages]) + sessions.filter_map { |session| blocked(session) || stalled(session) }
        end

        # @return [Array<Hash>] the red main's row while its flag stands
        def red(stages)
          flag = stages.is_a?(Array) && stages.find { |row| row[:name] == RED }
          flag ? [{ kind: "red_main", what: flag[:detail].to_s, since: "", owner_run: "", link: "/" }] : []
        end

        # @return [Hash, nil] a blocked session's row: the owner's to answer, or held for another
        def blocked(session)
          return unless session[:status] == "blocked"

          item(session, session[:owner] == true ? "owner_ask" : "blocked_run", session[:detail])
        end

        # @return [Hash, nil] a busy session's row when its job has written nothing for too long
        def stalled(session)
          return unless session[:status] == "busy"
          return unless Rules.verdict("Session idle", { idle_seconds: session[:idle_seconds] }) == "attention"

          item(session, "stalled_session", "no word for #{session[:idle_seconds].to_i / 60} min")
        end

        # @return [Hash] one `StuckItem`
        def item(session, kind, what)
          run = session[:run].to_s
          { kind: kind, what: what.to_s, since: session[:started].to_s, owner_run: run,
            link: run.empty? ? "" : "/runs/#{run}" }
        end
      end
    end
  end
end
