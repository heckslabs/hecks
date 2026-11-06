# frozen_string_literal: true

require_relative "../codebase/test_scope"

module Hecks
  module Adapters
    class SettingsReading
      # The `test scope` row of `hecks config`: where the full spec suite runs and how many spec
      # files one local call may run, and whether the Hecks world or the default says so.
      module TestScope
        # @param directory [String] the domain directory
        # @return [Array(String, String, String)] the row's name, value and source
        def test_scope(directory)
          declared = Codebase::TestScope.setting(Hecks.describe(directory).registry)
          return ["test scope", "no limit", "default"] if declared.empty?

          ["test scope", wording(declared), "world"]
        rescue StandardError => e
          ["test scope", "could not be read", first_line(e.message)]
        end

        def wording(declared)
          cap = declared[:spec_files_limit]
          calls = cap ? "at most #{cap} spec files per call locally" : "no cap on spec files per call"
          "full suite in #{declared[:suite_runs_in]}; #{calls}"
        end
      end
    end
  end
end
