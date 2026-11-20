# frozen_string_literal: true

require "hecks/pipeline_board/adapters/pipeline_stages"

# Calls for help as the board reads them, a few minutes old unless said otherwise.
module HelpQueueCalls
  NOW = Time.utc(2026, 11, 20, 13, 0, 0)

  def call(role: "coder", minutes: 5, needs: "login for X")
    { help: "help-stall-x", opened_at: (NOW - (minutes * 60)).iso8601, needs: needs, role: role, status: "open" }
  end

  def shown(*calls) = Hecks::Adapters::PipelineBoard::HelpQueue.lines(calls, NOW).map { |row| row[:line] }
end
