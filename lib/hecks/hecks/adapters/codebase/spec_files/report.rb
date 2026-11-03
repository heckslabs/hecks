# frozen_string_literal: true

module Hecks
  module Adapters
    module Codebase
      class SpecFiles
        # How one file ended.
        #
        # @!attribute [r] file
        #   @return [String] the spec file, as named
        # @!attribute [r] examples
        #   @return [Integer] how many examples ran
        # @!attribute [r] failures
        #   @return [Integer] how many failed
        # @!attribute [r] failed
        #   @return [Boolean] whether the file failed: a failed example, or a file that did not load
        # @!attribute [r] output
        #   @return [String] what the runner printed for the file (empty when it shared a process)
        Ending = Struct.new(:file, :examples, :failures, :failed, :output)

        # The report of several files: what failing files printed, a line for each file, the
        # isolation, the files that failed, and the total counts as the test runner spells them.
        class Report
          NOTES = {
            "process" => "isolation: process (a new process for each file)",
            "shared"  => "isolation: shared (one process; may expose order dependence)"
          }.freeze

          # @param endings [Array<Ending>] how each file ended
          # @param isolation [String] one of `SpecFiles::ISOLATIONS`
          # @param printed [String, nil] what the one shared process printed
          def initialize(endings, isolation, printed: nil)
            @endings = endings
            @isolation = isolation
            @printed = printed
          end

          # @return [Boolean] whether any file failed
          def failed? = @endings.any?(&:failed)

          # @return [String] the report, ending with the total example and failure counts
          def to_s = [@printed, *details, table, verdict, totals].compact.join("\n\n")

          private

          def failing = @endings.select(&:failed)

          def details
            failing.reject { |one| one.output.to_s.empty? }.map { |one| "--- #{one.file} ---\n#{one.output}" }
          end

          def table = (["files:"] + @endings.map { |one| "  #{line(one)}" }).join("\n")

          def line(one)
            "#{one.file}: #{plural(one.examples, "example")}, #{plural(one.failures, "failure")}#{"  FAILED" if one.failed}"
          end

          def verdict
            return NOTES.fetch(@isolation) unless failed?

            "#{NOTES.fetch(@isolation)}\nfailed: #{failing.map(&:file).join(" ")} (#{failing.size} of #{@endings.size} files)"
          end

          def totals = "#{plural(@endings.sum(&:examples), "example")}, #{plural(@endings.sum(&:failures), "failure")}"

          def plural(count, word) = "#{count} #{word}#{"s" unless count == 1}"
        end
      end
    end
  end
end
