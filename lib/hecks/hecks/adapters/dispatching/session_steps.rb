# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      class Launcher
        # The steps after a clear start: enlist the item and hand its brief to a session. It
        # reads the launcher's own `started_clear`, `enlist`, `dispatch`, `brief` and
        # `started_line`.
        module SessionSteps
          private

          # Clears the start, enlists the item and hands its brief to a session.
          #
          # @return [String] the started line
          def session(item, started, asked)
            started_clear(item, started)
            enlist(item)
            dispatch(item, brief(item, batch: BatchBrief.text(item), **asked))
            started_line(item, started.note)
          end

          # The keywords a brief is composed with.
          def brief_args(held, limit, lines) = { limit: limit, held: held, **lines }
        end
      end
    end
  end
end
