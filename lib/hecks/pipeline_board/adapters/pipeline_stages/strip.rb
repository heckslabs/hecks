# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/red_flag_report"
require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # The pipeline strip: one row per stage, left to right, each with a state word, a count and a
      # one-line detail. A stage whose section could not be read says `unknown: <reason>` and the
      # others still answer.
      module Strip
        module_function

        # @param data [Hash] the board's sections
        # @param now [Time] the time the stages are read at
        # @return [Array<Hash>] `name`, `state`, `count` and `detail` for each stage
        def build(data, now)
          [*flag(data[:red_flag], now), work(data[:counts]), sessions(data[:sessions]), local(data[:local]),
           train(data[:train], now), ci(data[:ci_runs]), promote(data[:stable]), release(data[:release])]
        end

        # The red flag row, first in the strip while a flag stands: its commit, the minutes main has
        # been red, and who has checked in. Nothing while main is not flagged or the read failed.
        def flag(standing, now)
          return [] unless standing.is_a?(Hash) && standing.key?("id")

          report = Hecks::Adapters::RedFlagReport.new(standing, now: now)
          [row("Red flag", state("Red flag"), standing["id"], report.text.tr("\n", "; "))]
        end

        def row(name, state, count, detail) = { name: name, state: state, count: count.to_s, detail: detail }

        # The state the bluebook's `Verdict` rows give a stage for what was read.
        def state(stage, measures = {}) = Rules.verdict(stage, measures)

        def unknown(name, section)
          reason = section.is_a?(Hash) ? section[:unknown] : "no data"
          row(name, "unknown", "-", "unknown: #{reason}")
        end

        def bad?(section) = section.nil? || (section.is_a?(Hash) && section.key?(:unknown))

        def work(counts)
          return unknown("Work items", counts) if bad?(counts)

          planned, started, done = %w[planned started done].map { |status| counts.fetch(status, 0) }
          row("Work items", state("Work items", started: started), "#{planned}/#{started}/#{done}", "planned / started / done")
        end

        # The Sessions row also names the sessions blocked on a person (`blocked`), so the page can
        # open an answer prompt for each: its run key, repo, work item and the question it waits on.
        def sessions(list)
          return unknown("Sessions", list) unless list.is_a?(Array)

          session_row(list.size, list.count { |s| s[:status] == "busy" }, list.select { |s| s[:status] == "blocked" })
        end

        def session_row(total, busy, waiting)
          note = "#{busy} busy, #{waiting.size} blocked on you, of #{total} in the last day"
          row("Sessions", state("Sessions", busy: busy, blocked: waiting.size), busy + waiting.size, note)
            .merge(blocked: waiting.map { |s| waiting_on(s) })
        end

        # The fields an answer prompt shows. The question is the job's own detail, when it has one.
        def waiting_on(session)
          { id: session[:id], name: session[:name], run: session[:run], repo: session[:repo],
            context: session[:context], attach: session[:attach], work_item: session[:work_item],
            question: session[:detail] }
        end

        def local(main)
          return unknown("Local main", main) if bad?(main)

          tree = main[:dirty].zero? ? "clean" : "#{main[:dirty]} changed files"
          note = "#{main[:ahead]} ahead, #{main[:behind]} behind origin/main; #{tree}"
          row("Local main", state("Local main", ahead: main[:ahead]), main[:ahead], note)
        end

        def train(info, now)
          return unknown("Train", info) if bad?(info)

          age = info[:at] ? ((now - Time.parse(info[:at])) / 3600.0).round(1) : "?"
          note = "last push #{age} h ago#{"; not on origin/main" unless info[:pushed]}"
          row("Train", state("Train", not_pushed: info[:pushed] ? 0 : 1), info[:sha], note)
        end

        def ci(runs)
          return unknown("CI", runs) unless runs.is_a?(Array) && runs.any?

          last = runs.last
          verdict = last[:conclusion].empty? ? last[:status] : last[:conclusion]
          failed = last[:failed_jobs] || "?"
          note = "#{last[:sha]} #{verdict}, #{last[:wall_minutes]} min, #{failed} failed jobs"
          row("CI", state("CI", ci_measures(last)), failed, note)
        end

        # What the CI verdict rows compare: whether the run is still going, and whether it ended in
        # anything but success.
        def ci_measures(run)
          { running: run[:status] == "completed" ? 0 : 1, unsuccessful: run[:conclusion] == "success" ? 0 : 1 }
        end

        def promote(stable)
          return unknown("Promote", stable) if bad?(stable)

          note = "stable #{stable[:sha]}; #{stable[:behind]} commits behind main"
          row("Promote", state("Promote", behind: stable[:behind]), stable[:behind], note)
        end

        def release(info)
          return unknown("Release", info) if bad?(info)

          word = info[:published] ? "published" : "not published"
          row("Release", state("Release", unpublished: info[:published] ? 0 : 1), info[:tag], word)
        end
      end
    end
  end
end
