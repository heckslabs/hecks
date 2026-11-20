# frozen_string_literal: true

require "json"
require_relative "../ledger_gate"
require_relative "plan_tile"
require_relative "integration_tile"
require_relative "stale"
require_relative "../pipeline_github/log_backoff"

module Hecks
  module Adapters
    module PipelineBoard
      # Asks each reader its question and keeps the answer, or `{unknown: <reason>}` when the reader
      # could not answer, so one failed read never takes the others down. The reads run side by
      # side and each has {READ_SECONDS} to answer, so one slow reader never holds the rest. A
      # section whose read was skipped shows its last answer, noted as stale (see {Stale}). The
      # readers of a shared ledger take turns (see {LedgerGate}).
      module Gather
        include PlanTile
        include IntegrationTile
        include Stale

        # Seconds one reader may take before its section is given as unknown.
        READ_SECONDS = 20

        # Seconds a reader told to stop is given to end.
        STOP_SECONDS = 1

        # A section whose reader from an earlier refresh has not finished.
        STILL_RUNNING = { unknown: "the last read is still running" }.freeze

        # Each section: the reader, its method, whether it answers rows of its own (`rows`, taken
        # as plain data) or an answer kept as it is (`plain`), and arguments.
        READS = {
          ci_runs: %i[github ci_runs plain], slowest_jobs: [:github, :slowest, :plain, "main"],
          train_ci_runs: %i[github train_ci_runs plain], train_slowest_jobs: [:github, :slowest, :plain, "train"],
          train_flakes: %i[github flakes plain],
          release: %i[github latest_release plain], local: %i[git local_main plain],
          train: %i[git train plain], stable: %i[git stable plain],
          open_work: %i[tickets undone_work rows], counts: %i[tickets counts plain],
          landed: %i[tickets landed_branches plain], stopped_runs: %i[tickets stopped_runs plain],
          stopped_times: %i[journal stopped_times plain],
          sessions: %i[jobs rows rows],
          red_flag: %i[git red_flag plain], fill: %i[fill preview plain], events: [:journal, :recent, :plain, 40],
          finished: [:journal, :named, :plain, "WorkFinished", 200], finished_times: %i[tickets finished_times plain],
          landed_times: %i[journal landed_times plain], disk: %i[disk free plain],
          boots: %i[boots today plain], open_prs: %i[github open_prs plain],
          cycle_events: %i[journal cycle_events plain], health_events: %i[journal health_events plain],
          open_findings: %i[tickets open_findings plain], integration: %i[integration reading plain],
          window_opened: [:journal, :named, :plain, "WindowOpened", 3],
          window_closed: [:journal, :named, :plain, "WindowClosed", 3],
          train_prs: %i[github train_prs plain], turns: %i[journal turns plain]
        }.freeze

        private

        def guard
          yield
        rescue PipelineBoard::Unavailable => e
          { unknown: e.message }
        rescue StandardError => e
          { unknown: "#{e.class}: #{e.message.to_s.slice(0, 100)}" }
        end

        # A reader's own rows as plain data: symbols and times as the words the page reads.
        def plain_rows
          guard { plain(yield) }
        end

        def read(spec)
          reader, method, kind, *args = spec
          ask = -> { LedgerGate.through(reader) { instance_variable_get("@#{reader}").public_send(method, *args) } }
          kind == :rows ? plain_rows(&ask) : guard(&ask)
        end

        def gathered
          threads = READS.to_h { |section, spec| [section, reading(section, spec)] }
          deadline = Time.now + read_seconds
          threads.to_h do |section, thread|
            [section, lasting(section, thread ? answer_of(section, thread, deadline) : STILL_RUNNING)]
          end
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
          marked = PipelineBoard::OwnerQueue.mark(data[:sessions], data[:open_work], root)
          data.merge(sessions: marked, waiting_on_you: PipelineBoard::OwnerQueue.reading(marked))
        end

        def read_seconds = @read_seconds || READ_SECONDS

        # The reader's answer, or unknown past the deadline. A reader past it is stopped (its
        # command reaps its own process group), and the next refresh reads the section again once
        # the thread has ended; a thread inside a call that cannot be interrupted stays on record,
        # so the next refresh does not start a second one.
        def answer_of(section, thread, deadline)
          return finished(section, thread) if thread.join([deadline - Time.now, 0].max)

          report_overdue(section, thread)
          stopped(section, thread)
          { unknown: "reader did not answer in #{read_seconds}s" }
        end

        # Names where an overdue reader is, in the board's log, on one line: the section, the
        # seconds and the innermost board frame. A section is named once for each back-off window
        # (see {LogBackoff}), on a table the board keeps, not once for each read.
        def report_overdue(section, thread)
          notes = (@overdue_notes ||= LogBackoff.new)
          return if notes.held?(section)

          notes.failed!(section)
          frames = thread.backtrace || []
          frame = frames.find { |line| line.include?("/pipeline_board/") } || frames.first
          warn "board: #{section} reader overdue after #{read_seconds}s at #{frame}"
        end

        def stopped(section, thread)
          thread.kill
          thread.join(STOP_SECONDS)
          @running.delete(section) unless thread.alive?
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
