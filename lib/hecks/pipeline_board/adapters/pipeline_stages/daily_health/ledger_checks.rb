# frozen_string_literal: true

require "time"
require_relative "../../rules"

module Hecks
  module Adapters
    module PipelineBoard
      module DailyHealth
        # The checks of the daily health line that read what the board already reads, with an age
        # bound added: `left` on the Jobs reading of the sessions, and `aged` on the open findings
        # of the ledger, aged by the event that opened each. It reads nothing.
        module LedgerChecks
          module_function

          # @param row [Hash] a `HealthCheck` row whose test is `left`
          # @param sessions [Array<Hash>] the Jobs reading: `id`, `status`, `state`, `started` and
          #   `ended`
          # @param now [Time]
          # @return [Array<Hash>] each session left past the bound, with `key`, `name`, `state` and
          #   `minutes`
          def left(row, sessions, now)
            bound = Rules.setting(row[:bound])
            words = row[:opens].split
            sessions.select { |session| left?(session, words) }.filter_map do |session|
              minutes = minutes_since(session, now)
              { key: session[:id], name: session[:name], state: session[:state], minutes: minutes } if minutes.to_i > bound
            end
          end

          # Minutes since the session ended, or started when it has not ended; nil when it says
          # neither.
          def minutes_since(session, now)
            stamp = session.values_at(:ended, :started).compact.first
            stamp && ((now - Time.parse(stamp.to_s)) / 60).round
          end

          # @param row [Hash] a `HealthCheck` row whose test is `aged`
          # @param open [Array<Hash>] the open findings, each with its `finding` key
          # @param events [Array<Hash>] board rows, oldest first
          # @param now [Time]
          # @return [Array<Hash>] each finding open past the bound, or opened before the log
          #   reaches, with `key`, `since` and `hours` (nil when the log does not reach it)
          def aged(row, open, events, now)
            bound = Rules.setting(row[:bound])
            opened = opened_at(row, events)
            open.filter_map do |finding|
              since = opened[finding[:finding]]
              hours = since && ((now - Time.parse(since)) / 3600).round
              { key: finding[:finding], since: since, hours: hours } if hours.nil? || hours > bound
            end
          end

          # The first opening event of each key.
          def opened_at(row, events)
            names = row[:opens].split
            events.each_with_object({}) do |event, held|
              held[event[:id]] ||= event[:at] if names.include?("#{event[:aggregate]}.#{event[:name]}")
            end
          end

          # Whether the session matches one of the row's `field:value` words.
          def left?(session, words)
            words.any? { |word| word.split(":", 2).then { |field, value| session[field.to_sym].to_s == value } }
          end
        end
      end
    end
  end
end
