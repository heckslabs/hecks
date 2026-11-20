# frozen_string_literal: true

module Hecks
  module Adapters
    class RunRecords
      # One acceptance reference read against a behaviors run's report: the `.behaviors` file and
      # the scenario the reference names, and how that one scenario ended in the report. Other
      # scenarios in the same report are not read.
      class AcceptanceReport
        # A per-test line of a behaviors report: its marker, then the test's description.
        TEST_LINE = /^\s+(ok|FAIL|ERROR)\s+(.+?)\s*$/

        # @return [String] the `.behaviors` file the reference names
        attr_reader :file

        # @return [String] the scenario the reference names
        attr_reader :scenario

        # @param ref [String] `<path>.behaviors#<scenario>`
        def initialize(ref)
          @file, @scenario = ref.to_s.split("#", 2).map(&:to_s)
        end

        # @param report [String] the run's per-test report
        # @return [String] `passed`, `failed`, or `unresolved` when no test bears its name
        def result(report)
          marker = marker_of(report)
          return "unresolved" unless marker

          marker == "ok" ? "passed" : "failed"
        end

        private

        # The marker of the test line that bears the scenario's name, or nil.
        def marker_of(report)
          line = report.to_s.scan(TEST_LINE).find { |(_, description)| description == scenario }
          line&.first
        end
      end
    end
  end
end
