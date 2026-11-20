# frozen_string_literal: true

require "json"
require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # What failed on an earlier attempt of a train pull request's CI run that a later attempt of
      # the same run passed, projected from the `CiRunRecord` rows (see {CiRecords}); GitHub is
      # never asked. An item is a failed job's name, counted once per run. A run whose earlier
      # attempt left no done record, or one without its jobs, is counted as `unreadable`: the beat
      # records only what it happens to see, so the answer says how partial it is.
      module TrainFlakes
        # How many days back the flakes reach.
        WINDOW_DAYS = 14

        # The conclusions that count a job as failed.
        FAILED = %w[failure timed_out cancelled startup_failure].freeze

        private

        def flake_document(limit)
          groups = train_groups
          raise PipelineBoard::Unavailable, "no train CI run is recorded yet" if groups.empty?

          found = windowed(groups).map { |seen| flaked(seen) }
          { window_days: WINDOW_DAYS, reaches_back: pushes(groups).min,
            unreadable: found.count(&:nil?), flakes: tally(found.compact).first(limit) }
        end

        # When each recorded train run was pushed.
        # The document as `Flake` rows: each flake with its branches named, and on each row how
        # far back the runs read reach and how many could not be read.
        def flake_rows(document)
          seen = { reaches_back: document[:reaches_back].to_s, unreadable: document[:unreadable].to_i }
          document[:flakes].map do |flake|
            branches = flake[:prs].map { |pull| pull[:branch] }.join(", ")
            flake.slice(:item, :kind, :count).merge(branches: branches, **seen)
          end
        end

        def pushes(groups) = groups.flatten.map { |row| row[:pushed] }.reject(&:empty?)

        # The records of each train run, every attempt together.
        def train_groups = record_rows.select { |row| row[:lane] == "train" }.group_by { |row| row[:id] }.values

        # The passed reruns pushed within the window.
        def windowed(groups)
          since = Time.now - (WINDOW_DAYS * 86_400)
          groups.select { |seen| passed_rerun?(seen) && pushed_since?(seen, since) }
        end

        def passed_rerun?(seen)
          head = newest(seen)
          head[:attempt] > 1 && head[:done] && head[:conclusion] == "success"
        end

        def pushed_since?(seen, since)
          Time.parse(seen.first[:pushed]) >= since
        rescue ArgumentError
          false
        end

        # The items one passed rerun cleared, or nil when an earlier attempt cannot be read from
        # the records.
        def flaked(seen)
          earlier = earlier_attempts(seen)
          return if earlier.any? { |row| row.nil? || row[:jobs].empty? }

          head = newest(seen)
          { branch: head[:branch], url: head[:url], items: earlier.flat_map { |row| failed_items(row) }.uniq }
        rescue JSON::ParserError
          nil
        end

        # The done record of each attempt before the newest, nil for one that was never seen done.
        def earlier_attempts(seen)
          (1...newest(seen)[:attempt]).map { |number| seen.find { |row| row[:attempt] == number && row[:done] } }
        end

        def failed_items(row)
          jobs = JSON.parse(row[:jobs], symbolize_names: true)
          jobs.select { |job| FAILED.include?(job[:conclusion]) }.map { |job| { item: job[:name], kind: "job" } }
        end

        def tally(found)
          grouped = found.flat_map { |run| run[:items].map { |item| [item, run] } }.group_by(&:first)
          rows = grouped.map { |item, pairs| flake_row(item, pairs.map(&:last)) }
          rows.sort_by { |row| [-row[:count], row[:item]] }
        end

        def flake_row(item, runs)
          { item: item[:item], kind: item[:kind], count: runs.size,
            prs: runs.map { |run| { branch: run[:branch], url: run[:url] } } }
        end
      end
    end
  end
end
