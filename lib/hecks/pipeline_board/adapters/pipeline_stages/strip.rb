# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/red_flag_report"

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
          [row("Red flag", "failed", standing["id"], report.text.tr("\n", "; "))]
        end

        def row(name, state, count, detail) = { name: name, state: state, count: count.to_s, detail: detail }

        def unknown(name, section)
          reason = section.is_a?(Hash) ? section[:unknown] : "no data"
          row(name, "unknown", "-", "unknown: #{reason}")
        end

        def bad?(section) = section.nil? || (section.is_a?(Hash) && section.key?(:unknown))

        def work(counts)
          return unknown("Work items", counts) if bad?(counts)

          planned, started, done = %w[planned started done].map { |status| counts.fetch(status, 0) }
          row("Work items", started.positive? ? "working" : "ok", "#{planned}/#{started}/#{done}", "planned / started / done")
        end

        # The Sessions row also names the sessions blocked on a person (`blocked`), so the page can
        # open an answer prompt for each: its run key, repo, work item and the question it waits on.
        def sessions(list)
          return unknown("Sessions", list) unless list.is_a?(Array)

          session_row(list.size, list.count { |s| s[:status] == "busy" }, list.select { |s| s[:status] == "blocked" })
        end

        def session_row(total, busy, waiting)
          note = "#{busy} busy, #{waiting.size} blocked on you, of #{total} in the last day"
          row("Sessions", session_state(busy, waiting.size), busy + waiting.size, note)
            .merge(blocked: waiting.map { |s| waiting_on(s) })
        end

        # The fields an answer prompt shows. The question is the job's own detail, when it has one.
        def waiting_on(session)
          { id: session[:id], name: session[:name], run: session[:run], repo: session[:repo],
            work_item: session[:work_item], question: session[:detail] }
        end

        # Attention while anyone waits on a person, working while anyone works, else ok.
        def session_state(busy, blocked)
          return "attention" if blocked.positive?

          busy.positive? ? "working" : "ok"
        end

        def local(main)
          return unknown("Local main", main) if bad?(main)

          tree = main[:dirty].zero? ? "clean" : "#{main[:dirty]} changed files"
          note = "#{main[:ahead]} ahead, #{main[:behind]} behind origin/main; #{tree}"
          row("Local main", main[:ahead].zero? ? "ok" : "attention", main[:ahead], note)
        end

        def train(info, now)
          return unknown("Train", info) if bad?(info)

          age = info[:at] ? ((now - Time.parse(info[:at])) / 3600.0).round(1) : "?"
          note = "last push #{age} h ago#{"; not on origin/main" unless info[:pushed]}"
          row("Train", info[:pushed] ? "ok" : "attention", info[:sha], note)
        end

        def ci(runs)
          return unknown("CI", runs) unless runs.is_a?(Array) && runs.any?

          last = runs.last
          verdict = last[:conclusion].empty? ? last[:status] : last[:conclusion]
          failed = last[:failed_jobs] || "?"
          note = "#{last[:sha]} #{verdict}, #{last[:wall_minutes]} min, #{failed} failed jobs"
          row("CI", ci_state(last), failed, note)
        end

        def ci_state(run)
          return "working" unless run[:status] == "completed"

          Hecks::CheckConclusion.certifies?(run[:conclusion]) ? "ok" : "failed"
        end

        def promote(stable)
          return unknown("Promote", stable) if bad?(stable)

          note = "stable #{stable[:sha]}; #{stable[:behind]} commits behind main"
          row("Promote", stable[:behind].zero? ? "ok" : "attention", stable[:behind], note)
        end

        def release(info)
          return unknown("Release", info) if bad?(info)

          row("Release", info[:published] ? "ok" : "attention", info[:tag], info[:published] ? "published" : "not published")
        end
      end
    end
  end
end
