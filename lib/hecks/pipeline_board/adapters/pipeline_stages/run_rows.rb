# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The sessions that hold a run, as the bluebook's `RunCard` rows: the run, its role, its
      # session and condition, its Work item, the seconds since its job last wrote, and its last
      # word, the verdict of the run's newest finished turn.
      module RunRows
        module_function

        # @param sessions [Array<Hash>] the sessions as the Jobs reader answered them
        # @param turns [Array<Hash>] the finished turns, oldest first, each with `run` and `verdict`
        # @return [Array<Hash>] one `RunCard` per session that holds a run
        def of(sessions, turns)
          words = turns.to_h { |turn| [turn["run"].to_s, turn["verdict"].to_s] }
          sessions.reject { |session| session[:run].to_s.empty? }.map { |session| card(session, words) }
        end

        # @return [Hash] one `RunCard`
        def card(session, words)
          run = session[:run].to_s
          { run: run, role: role_of(session), session: session[:id].to_s, condition: session[:state].to_s,
            work_item: session[:work_item].to_s, idle_seconds: session[:idle_seconds].to_i,
            last_word: words.fetch(run, ""), link: "/runs/#{run}" }
        end

        # @return [String] the part the run works as, else the agent it is
        def role_of(session)
          [session[:works_as], session[:agent]].map(&:to_s).find { |word| !word.empty? }.to_s
        end
      end
    end
  end
end
