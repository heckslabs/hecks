# frozen_string_literal: true

require "fileutils"
require_relative "../../../console_capture"

module Hecks
  module Adapters
    module Codebase
      module TestSuite
        module StressRun
          # The verdict of a stress run: the clean line, or each failing run's saved log and how to
          # reproduce it.
          class Verdict
            # A parenthesis, which a saved log's file name leaves out.
            PARENTHESIS = /[()]/

            # @param root [String] the checkout; failing runs' output is saved under its `tmp/`
            # @param results [Array<Hash>] every run's result
            def initialize(root, results)
              @root = root
              @results = results
            end

            # @param announcement [String] what was run
            # @return [String] the announcement and the clean verdict
            # @raise [ConsoleCapture::Failure] with the announcement and each failure, on flakiness
            def text(announcement)
              failures = @results.reject { |result| result[:success] }
              return "#{announcement}\n\n#{clean}" if failures.empty?

              lines = ["FOUND FLAKINESS — #{failures.size}/#{@results.size} runs failed:"]
              raise ConsoleCapture::Failure, ([announcement, ""] + lines + failures.map { |f| saved(f) }).join("\n")
            end

            # @return [String] the line a clean run ends with
            def clean
              "CLEAN — #{@results.size}/#{@results.size} runs passed. " \
                "No new flakiness beyond a single ordinary `rspec` run found in this many tries."
            end

            # Saves a failing run's full output under `tmp/stress-failures/`.
            #
            # @param failure [Hash] a failed run's result
            # @return [String] where the log went and how to reproduce the run
            def saved(failure)
              dir = File.join(@root, "tmp/stress-failures")
              FileUtils.mkdir_p(dir)
              name = "#{failure[:label].tr(" ", "_").gsub(PARENTHESIS, "")}-seed#{failure[:seed]}.log"
              File.write(File.join(dir, name), failure[:output])
              "  [#{failure[:label]}] seed #{failure[:seed]} — output saved to tmp/stress-failures/#{name}\n    " \
                "reproduce: #{failure[:reproduce]}"
            end
          end
        end
      end
    end
  end
end
