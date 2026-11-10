# frozen_string_literal: true

require "time"
require_relative "../rules"
require_relative "daily_health/event_checks"
require_relative "daily_health/ledger_checks"

module Hecks
  module Adapters
    module PipelineBoard
      # The pipeline's own day, laid against the `HealthCheck` rows: what a person would otherwise
      # find by watching, each finding with its age, one line that says it all and the board's
      # tile. The rows say what each check opens and closes on; this module hands each row its
      # reading and counts. It reads nothing and alerts no one.
      module DailyHealth
        # The section each test reads.
        SECTIONS = { "left" => :sessions, "aged" => :open_findings }.freeze

        module_function

        # @return [Array<Hash>] the `HealthCheck` rows, in the order they are written
        def checks = Rules.rows("HealthCheck")

        # @return [Array<String>] the bare event names the rows open and close on (a `left` row's
        #   `opens` names session states, not events)
        def event_names = event_checks.flat_map { |row| bare_names(row) }.uniq

        # @return [Array<String>] a row's opening and closing events, without their aggregates
        def bare_names(row) = "#{row[:opens]} #{row[:closes]}".split.map { |name| name.split(".").last }

        # @return [Array<Hash>] the rows that open and close on events
        def event_checks = checks.reject { |row| row[:test] == "left" }

        # @param data [Hash] `health_events` (board rows), `sessions` (the Jobs reading) and
        #   `open_findings`, each an answer or `{unknown: reason}`
        # @param now [Time]
        # @return [Hash] one entry per check kind (its findings, or the `{unknown:}` of its
        #   reading), `unreadable` (boardings whose commit link cannot be read) and `line`
        def build(data, now)
          events = ordered(data[:health_events])
          since = now - (Rules.setting("health_window_hours") * 3600)
          found = checks.to_h { |row| [row[:kind].to_sym, check(row, data, events, now, since)] }
          found.merge(unreadable: unreadable(events, since)).then { |report| report.merge(line: line(report, now)) }
        end

        # @return [Array<Hash>, nil] the events oldest first, nil when they could not be read
        def ordered(events) = events.is_a?(Array) ? events.sort_by { |event| event[:at].to_s } : nil

        # @param report [Hash] from `build`
        # @return [Hash] the board's tile: how many findings only the events show
        def tile(report)
          counted = checks.select { |row| row[:counted] == "yes" }.map { |row| report[row[:kind].to_sym] }
          found = counted.all?(Array) ? counted.sum(&:size) : nil
          { id: "health", label: "Pipeline health", value: found, unit: "", trend: nil,
            state: Rules.verdict("Pipeline health", { found: found }), detail: report[:line].to_s }
        end

        # @return [String] the day, then each check that found something, with its count
        def line(report, now)
          said = checks.filter_map { |row| said(row, report[row[:kind].to_sym]) }
          unread = report[:unreadable]
          said << "#{unread.size} boardings with an unreadable commit" if unread.is_a?(Array) && unread.any?
          "pipeline health #{now.utc.strftime("%F")}: #{said.empty? ? "nothing found" : said.join(", ")}"
        end

        def said(row, found)
          return "#{row[:says]} unknown (#{found[:unknown]})" unless found.is_a?(Array)

          "#{found.size} #{row[:says]} (#{found.map { |entry| brief(entry) }.join(" ")})" if found.any?
        end

        # One finding as the line names it: its key and, when measured, its age.
        def brief(entry)
          age = entry[:minutes] ? "#{entry[:minutes]}m" : (entry[:hours] && "#{entry[:hours]}h")
          [entry[:key].to_s[0, 12], age].compact.join(" ")
        end

        # A check whose reading failed answers that reading's `{unknown:}`. An `aged` check needs
        # the events as well, for when each key opened.
        def check(row, data, events, now, since)
          failed = failed_reading(row, data)
          return failed if failed

          case row[:test]
          when "left" then LedgerChecks.left(row, data[:sessions], now)
          when "aged" then LedgerChecks.aged(row, data[:open_findings], events, now)
          else EventChecks.found(row, events, now, since)
          end
        end

        # The `{unknown:}` of the first reading the check needs that failed, nil when all were read.
        def failed_reading(row, data)
          needed = [SECTIONS[row[:test]], (:health_events unless row[:test] == "left")].compact
          missing = needed.find { |name| !data[name].is_a?(Array) }
          missing && (data[missing] || { unknown: "nothing read" })
        end

        def unreadable(events, since)
          return [] unless events

          checks.select { |row| row[:joins].include?(" ") }.flat_map { |row| EventChecks.unreadable(row, events, since) }
                .uniq { |entry| entry[:key] }
        end
      end
    end
  end
end
