# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Tells which blocked sessions are the owner's to answer. The adapter only measures (is the
      # session of another repository, has its Work item finished, did it ask the owner); the
      # `Session owner` rows of the bluebook decide, so the words are the bluebook's.
      module OwnerQueue
        ASKED = /\A\s*\[owner\]/i
        REVIEW = /\A\s*\[review\]/i
        NEEDS_ANSWER = "needs an answer:"
        LIVE = %w[busy blocked].freeze

        module_function

        # @param sessions [Array<Hash>, Object] the board's session rows
        # @param open_work [Array<Hash>, Object] the undone Work items, or `{unknown:}`
        # @param root [String] the checkout the pipeline runs in
        # @return [Array<Hash>, Object] the rows, each live one with `kind:` (the `Session owner`
        #   word: running, owner, finished leftover, other repo, ...) and each blocked one also with
        #   `owner:` and, when not the owner's, `held:` naming what it is; other rows and an
        #   unreadable list pass through
        def mark(sessions, open_work, root)
          return sessions unless sessions.is_a?(Array)

          sessions.map { |row| classed(row, open_work, root) }
        end

        # @param session [Hash] a session row
        # @return [Boolean] whether the session is blocked on the owner
        def waiting?(session) = session[:status] == "blocked" && session[:owner] == true

        def classed(row, work, root)
          return row unless LIVE.include?(row[:status])

          state = Rules.verdict("Session owner", measures(row, work, root))
          row.merge(blocked_marks(row, state)).merge(kind: state)
        end

        def blocked_marks(row, state)
          return {} unless row[:status] == "blocked"

          state == "owner" ? { owner: true } : { owner: false, held: state }
        end

        def measures(row, work, root)
          { blocked: flag(row[:status] == "blocked"), other_repo: flag(elsewhere?(row, root)),
            finished: flag(finished?(row, work)), asked: flag(asked?(row, work)), review: flag(said(row).match?(REVIEW)) }
        end

        def flag(condition) = condition ? 1 : 0

        def said(row) = (row.dig(:context, :said) || row[:detail]).to_s

        # A session with no run whose directory lies outside the checkout is not the pipeline's.
        def elsewhere?(row, root)
          cwd = row[:cwd].to_s
          row[:run].to_s.empty? && !cwd.empty? && !(cwd == root || cwd.start_with?("#{root}/"))
        end

        def finished?(row, work)
          item = row[:work_item].to_s
          work.is_a?(Array) && !item.empty? && work.none? { |found| found[:slug] == item }
        end

        def asked?(row, work)
          row[:question_kind] == "owner" || said(row).match?(ASKED) || answer_item?(row[:run].to_s, work)
        end

        def answer_item?(run, work)
          work.is_a?(Array) && !run.empty? && work.any? do |found|
            found[:title].to_s.start_with?(NEEDS_ANSWER) && found[:title].to_s.include?(run)
          end
        end
      end
    end
  end
end
