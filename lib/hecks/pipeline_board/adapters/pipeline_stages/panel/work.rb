# frozen_string_literal: true

require_relative "kit"

module Hecks
  module Adapters
    module PipelineBoard
      module Panel
        # The panel's lower half: the sessions by state, the open train pull requests, the planned
        # Work items and the agents. Each method answers the rows of one box, `[text, tone]` each.
        class Work
          # The session states in the order they are listed, with the heading of each.
          GROUPS = { "blocked" => "blocked on you", "busy" => "working", "failed" => "failed", "done" => "done" }.freeze

          # @param state [Hash] the board's state, with `train_prs` where it was read
          # @param limit [Integer] how many rows a long list shows
          # @param size [Integer] the characters a row may hold
          def initialize(state, limit, size)
            @state = state
            @limit = limit
            @size = size
          end

          # @return [Array<Array(String, String)>] the sessions by state, blocked first, each state
          #   under a heading
          def sessions
            found = @state[:sessions]
            return [unknown(found)] unless found.is_a?(Array)

            GROUPS.flat_map { |status, heading| group(status, heading, found.select { |row| row[:status] == status }) }
          end

          # @return [Array<Array(String, String)>] each open train pull request, its checks counted
          def pulls
            found = @state[:train_prs]
            return [unknown(found)] unless found.is_a?(Array)
            return [["none open", "ok"]] if found.empty?

            found.map { |pull| pull_row(pull) }
          end

          # @return [Array<Array(String, String)>] the first planned Work items
          def planned
            found = @state[:open_work]
            return [unknown(found)] unless found.is_a?(Array)

            waiting = found.select { |item| item[:status] == "planned" }
            rows = waiting.first(@limit).map { |item| ["#{item[:slug]}  #{item[:title]}", "ok"] }
            rows << ["+#{waiting.size - @limit} more planned", "unknown"] if waiting.size > @limit
            rows.empty? ? [["none planned", "ok"]] : rows
          end

          # @return [Array<Array(String, String)>] the roles with their live sessions, the open plan
          #   reviews and the promotions recommended
          def agents
            [*roles, *reviews, *recommendations]
          end

          private

          def unknown(found)
            reason = found.is_a?(Hash) ? found[:unknown] : "no data"
            ["unknown: #{reason}", "unknown"]
          end

          def group(status, heading, rows)
            return [] if rows.empty?

            shown = status == "done" ? rows.first(@limit) : rows
            more = rows.size - shown.size
            lines = shown.map { |row| [session_line(row), status] }
            [["#{heading} (#{rows.size})", status], *lines, *(more.positive? ? [["  +#{more} more", "unknown"]] : [])]
          end

          def session_line(row)
            name = row[:run].to_s.empty? ? row[:name] : row[:run]
            role = row[:agent].to_s.empty? ? "" : " [#{row[:agent]}]"
            "  #{name}#{role} #{row[:detail]}"
          end

          def pull_row(pull)
            text = "##{pull[:number]} #{pull[:branch]}  #{pull[:total]} checks: #{pull[:passed]} passed, " \
                   "#{pull[:failed]} failed, #{pull[:pending]} pending"
            tone = pull[:pending].positive? ? "working" : "ok"
            [text, pull[:failed].positive? ? "failed" : tone]
          end

          def roles
            found = @state[:roles]
            return [unknown(found)] unless found.is_a?(Array)

            Kit.wrap(found.map { |role| ["#{role[:name]} #{role[:live]}", "ok"] }, @size, " | ")
          end

          def reviews
            found = @state[:reviews]
            return [unknown(found)] unless found.is_a?(Array)

            rows = found.first(@limit).map { |review| ["review #{review[:work]}: #{verdict(review)}", "attention"] }
            rows << ["+#{found.size - @limit} more reviews", "unknown"] if found.size > @limit
            rows
          end

          def verdict(review) = review[:verdict].to_s.empty? ? "no verdict yet" : review[:verdict]

          def recommendations
            found = @state[:recommendations]
            return [unknown(found)] unless found.is_a?(Array)

            found.map { |row| ["promotion recommended: #{row[:change]}", "attention"] }
          end
        end
      end
    end
  end
end
