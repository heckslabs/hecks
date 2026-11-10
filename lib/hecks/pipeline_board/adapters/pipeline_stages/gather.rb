# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Asks each reader its question and keeps the answer, or `{unknown: <reason>}` when the reader
      # could not answer, so one failed read never takes the others down. The reads run side by
      # side and each has {READ_SECONDS} to answer, so one slow reader never holds the rest.
      module Gather
        # Seconds one reader may take before its section is given as unknown.
        READ_SECONDS = 20

        # Each section: the reader, its method, whether it answers a query document, and arguments.
        READS = {
          ci_runs: [:github, :ci_runs, :query], slowest_jobs: [:github, :slowest_jobs, :query],
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
          cycle_events: %i[journal cycle_events plain]
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
          threads = READS.transform_values { |spec| Thread.new { read(spec) } }
          deadline = Time.now + read_seconds
          threads.transform_values { |thread| answer_of(thread, deadline) }
        end

        def read_seconds = @read_seconds || READ_SECONDS

        def answer_of(thread, deadline)
          return thread.value if thread.join([deadline - Time.now, 0].max)

          thread.kill
          { unknown: "reader did not answer in #{read_seconds}s" }
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
