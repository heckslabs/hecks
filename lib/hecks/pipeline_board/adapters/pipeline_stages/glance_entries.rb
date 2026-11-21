# frozen_string_literal: true

require "time"
require_relative "../rules"
require_relative "glance_entry"
require_relative "stuck_rows"
require_relative "overdue_row"

module Hecks
  module Adapters
    module PipelineBoard
      # What needs a person or stands too long, as the `Glance`'s `StuckItem` rows. Each member is
      # the facts of one kind (what the owning aggregate's query answered) judged by that kind's
      # `Verdict` row; a kind with no member row, such as a red main being reverted, is not listed.
      module GlanceEntries
        WAITING = "waiting on a person"
        GIVEN_UP = %w[parked unfound].freeze

        module_function

        # @param data [Hash] the board's sections as they were read
        # @param now [Time] the time the board is read at
        # @return [Array<Hash>] the entries, those waiting on a person first
        def of(data, now)
          found = [*sessions(data), *episodes(data, now), *approvals(data), *stops(data, now),
                   *trains(data, now), *epics(data, now), *idle(data)]
          found.each_with_index.sort_by { |item, place| [item[:group] == WAITING ? 0 : 1, place] }.map(&:first)
        end

        # @return [Array<Hash>] a blocked or stalled session's entry
        def sessions(data)
          listed(data[:sessions]).filter_map { |session| StuckRows.blocked(session) || StuckRows.stalled(session) }
                                 .map { |item| GlanceEntry.from(item) }
        end

        # @return [Array<Hash>] a standing red episode: given up waits on the owner, one still
        #   being reverted is no entry, any other is one once it stands past its mark
        def episodes(data, now)
          listed(data[:red_episodes]).filter_map do |episode|
            kind = episode_kind(episode, now)
            kind && GlanceEntry.of(kind, episode_what(episode), since: Time.at(episode[:began_at]).utc.iso8601, link: "/")
          end
        end

        # @return [Array<Hash>] an open approval only the owner can give
        def approvals(data)
          listed(data[:approvals]).map { |row| GlanceEntry.of("approval_awaited", row[:title], run: row[:finding]) }
        end

        # @return [Array<Hash>] a stopped run left past its mark
        def stops(data, now)
          late = OverdueRow.aged(data[:stopped_runs], data[:stopped_times], now).select { |stop| stop[:overdue] }
          late.map { |stop| GlanceEntry.of("stopped_run", OverdueRow.line(stop), run: stop[:finding]) }
        end

        # @return [Array<Hash>] a train pull request left past its mark
        def trains(data, now)
          left = listed(data[:train_prs]).select { |pull| aged?("Train PR age", minutes(pull[:created], now)) }
          left.map { |pull| GlanceEntry.of("train_blocked", "##{pull[:number]}", since: pull[:created], link: "/trains") }
        end

        # @return [Array<Hash>] an epic past its hold
        def epics(data, now)
          held = listed(data[:epics]).select { |epic| aged?("Epic hold age", past_hold(epic, now)) }
          held.map { |epic| GlanceEntry.of("epic_held", epic[:title], run: epic[:epic]) }
        end

        # @return [Array<Hash>] planned work the fill would start, left past its mark
        def idle(data)
          fill = data[:fill]
          return [] unless fill.is_a?(Hash) && Array(fill[:would_start]).any? && fill[:headroom].to_i.positive?
          return [] unless aged?("Planned idle age", fill[:age_minutes])

          [GlanceEntry.of("planned_idle", "#{fill[:would_start].size} planned, last fill #{fill[:age_minutes]} min ago")]
        end

        def episode_kind(episode, now)
          return "red_main_given_up" if GIVEN_UP.include?(episode[:status])
          return if episode[:status] == "reverting"

          "red_main" if aged?("Red main age", (now.to_i - episode[:began_at]) / 60.0)
        end

        def episode_what(episode) = "#{episode[:status]} #{episode[:culprit].to_s[0, 10]} #{episode[:branch]}".strip

        def aged?(stage, minutes) = Rules.verdict(stage, { age_minutes: minutes }) == "too long"

        def minutes(time, now) = time.to_s.empty? ? nil : (now - Time.parse(time)) / 60.0

        def past_hold(epic, now)
          return unless epic[:hand_ranked_at].to_i.positive?

          (now.to_i - epic[:hand_ranked_at] - epic[:hold].to_i) / 60.0
        end

        def listed(section) = section.is_a?(Array) ? section : []
      end
    end
  end
end
