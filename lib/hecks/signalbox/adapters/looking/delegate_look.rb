# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class Looking
      # Delegate's last fill and last shed, read from its `Dispatch` and `Shed` records: the work
      # item the fill started, or the first it left waiting, and the work item the shed asked to
      # yield. It reads the report Delegate wrote and decides nothing.
      class DelegateLook
        # A fill report's line for a work item it started, or would start.
        STARTED = /\A(?:would start|started) ([^\s:()]+)/
        # The load line of a fill that started nothing: `nothing starts; 3 waiting, first a, b`.
        FIRST_WAITING = /nothing starts; \d+ waiting, first ([^\s,]+)/
        # A report line for a work item left waiting: its key, then the reason.
        WAITING = /\A([a-z0-9][a-z0-9-]+) skipped/

        # @param registry [Runtime::Registry, nil] whose Hecks domain holds Delegate's records
        def initialize(registry)
          @registry = registry
        end

        # @return [Hash] `fill_subject:`, `fill_delegate:` (start, wait or none), `shed_subject:`
        #   and `shed_delegate:` (shed or none)
        def facts = fill.merge(shed)

        private

        def fill
          lines = report_lines
          started = lines.lazy.filter_map { |line| line[STARTED, 1] }.first
          return { fill_subject: started, fill_delegate: "start" } if started

          waiting = lines.lazy.filter_map { |line| line[FIRST_WAITING, 1] || line[WAITING, 1] }.first
          waiting ? { fill_subject: waiting, fill_delegate: "wait" } : { fill_subject: "nothing-planned", fill_delegate: "none" }
        end

        def shed
          last = records("Shed").last
          work = last && StartedWork.value(last, :work).to_s
          return { shed_subject: work, shed_delegate: "shed" } if work && !work.empty?

          { shed_subject: last ? StartedWork.value(last, :reading).to_s : "nothing-shed", shed_delegate: "none" }
        end

        # The lines of the newest Dispatch report that says something.
        def report_lines = last_report.to_s.lines.map(&:strip)

        def last_report
          reports = records("Dispatch").map { |record| StartedWork.value(record, :report).to_s }
          reports.reverse.find { |text| !text.empty? }
        end

        def records(name)
          aggregate = aggregates.find { |candidate| candidate.hecks_name == name }
          aggregate ? @registry.repository("Hecks", aggregate).all.to_a : []
        rescue StandardError
          []
        end

        def aggregates
          bluebook = @registry&.bluebook("Hecks")
          bluebook ? bluebook.aggregates : []
        end
      end
    end
  end
end
