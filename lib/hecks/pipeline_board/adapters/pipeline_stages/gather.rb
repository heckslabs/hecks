# frozen_string_literal: true

require "json"
require_relative "plan_tile"

module Hecks
  module Adapters
    module PipelineBoard
      # Asks each reader its question and keeps the answer, or `{unknown: <reason>}` when the reader
      # could not answer, so one failed read never takes the others down. The reads run side by
      # side and each has {READ_SECONDS} to answer, so one slow reader never holds the rest.
      module Gather
        include PlanTile

        # Seconds one reader may take before its section is given as unknown.
        READ_SECONDS = 20

        # A section whose reader from an earlier refresh has not finished.
        STILL_RUNNING = { unknown: "the last read is still running" }.freeze

        # Each section: the reader, its method, whether it answers a query document, and arguments.
        READS = {
          ci_runs: [:github, :ci_runs, :query], slowest_jobs: [:github, :slowest_jobs, :query],
          train_ci_runs: [:github, :train_ci_runs, :query], train_slowest_jobs: [:github, :train_slowest_jobs, :query],
          train_flakes: [:github, :train_flakes, :query],
          release: %i[github latest_release plain], local: %i[git local_main plain],
          train: %i[git train plain], stable: %i[git stable plain],
          open_work: [:tickets, :open_work, :query], counts: %i[tickets counts plain],
          landed: %i[tickets landed_branches plain], stopped_runs: %i[tickets stopped_runs plain],
          stopped_times: %i[journal stopped_times plain],
          sessions: [:jobs, :sessions, :query],
          red_flag: %i[git red_flag plain], fill: %i[fill preview plain], events: [:journal, :recent, :plain, 40],
          finished: [:journal, :named, :plain, "WorkFinished", 200],
          landed_times: %i[journal landed_times plain], promotions: %i[journal promotions plain], disk: %i[disk free plain],
          boots: %i[boots today plain], open_prs: %i[github open_prs plain],
          cycle_events: %i[journal cycle_events plain], health_events: %i[journal health_events plain],
          open_findings: %i[tickets open_findings plain]
        }.freeze

        private

        def guard
          yield
        rescue PipelineBoard::Unavailable => e
          { unknown: e.message }
        rescue StandardError => e
          { unknown: "#{e.class}: #{e.message.to_s.slice(0, 100)}" }
        end

        def queried
          guard { JSON.parse(yield[:text], symbolize_names: true) }
        end

        def read(spec)
          reader, method, kind, *args = spec
          ask = -> { instance_variable_get("@#{reader}").public_send(method, *args) }
          kind == :query ? queried(&ask) : guard(&ask)
        end

        def gathered
          threads = READS.to_h { |section, spec| [section, reading(section, spec)] }
          deadline = Time.now + read_seconds
          threads.to_h { |section, thread| [section, thread ? answer_of(section, thread, deadline) : STILL_RUNNING] }
        end

        # A new read of the section, or nil while the last one is still running, so a slow reader is
        # never asked twice at once and its threads cannot pile up.
        def reading(section, spec)
          running = (@running ||= {})
          return nil if running[section]&.alive?

          running[section] = Thread.new { read(spec) }
        end

        # The sessions, each blocked one marked as the owner's to answer or not (see {OwnerQueue}),
        # against the checkout the board is pointed at, else its own.
        def owned(data)
          named = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
          root = named.empty? ? @root : named
          data.merge(sessions: PipelineBoard::OwnerQueue.mark(data[:sessions], data[:open_work], root))
        end

        def read_seconds = @read_seconds || READ_SECONDS

        # The reader's answer, or unknown past the deadline. The thread is left to finish rather
        # than killed: its command stops itself at the Probe bound, and the next refresh skips the
        # section until it has.
        def answer_of(section, thread, deadline)
          return finished(section, thread) if thread.join([deadline - Time.now, 0].max)

          { unknown: "reader did not answer in #{read_seconds}s" }
        end

        def finished(section, thread)
          @running.delete(section) if @running[section].equal?(thread)
          thread.value
        end

        def dated(data)
          runs = data[:ci_runs]
          return {} unless runs.is_a?(Array)

          { commit_times: guard { @git.commit_times(runs.map { |run| run[:sha] }) } }
        end
      end
    end
  end
end
