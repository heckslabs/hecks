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
          return [] unless flag

          [{ kind: "red_main", what: flag[:detail].to_s, since: "", owner_run: "", link: "/" }.merge(sorted("red_main"))]
        end

        # @param kind [String] a `StuckKind`
        # @param said [String] who the item itself says it waits on, used where the row names none
        # @return [Hash] the `group` the kind's row gives and who it `waits_on`
        def sorted(kind, said = "")
          found = Rules.rows("StuckKind").find { |held| held[:kind] == kind } || {}
          { group: found[:group].to_s, waits_on: found[:waits_on].to_s.empty? ? said.to_s : found[:waits_on] }
        end

        # @return [Hash, nil] a blocked session's row: the owner's to answer, or held for another
        def blocked(session)
          return unless session[:status] == "blocked"

          kind = session[:owner] == true ? "owner_ask" : "blocked_run"
          item(session, kind, session[:detail]).merge(sorted(kind, session[:held]))
        end

        # @return [Hash, nil] a busy session's row when its job has written nothing for too long
        def stalled(session)
          return unless session[:status] == "busy"
          return unless Rules.verdict("Session idle", { idle_seconds: session[:idle_seconds] }) == "attention"

          item(session, "stalled_session", "no word for #{session[:idle_seconds].to_i / 60} min")
            .merge(sorted("stalled_session"))
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
