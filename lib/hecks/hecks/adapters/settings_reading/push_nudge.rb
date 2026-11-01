# frozen_string_literal: true

require_relative "../../../quality_control/adapters/push_due_reader"

module Hecks
  module Adapters
    class SettingsReading
      # The `push nudge` row of `hecks config`: how many commits or hours local main may drift ahead
      # of origin/main before QA files the `push-due` Work row, and whether the QualityControl world
      # or the default says so.
      module PushNudge
        # @param directory [String] the domain directory
        # @return [Array(String, String, String)] the row's name, value and source
        def push_nudge(directory)
          registry = Hecks.describe(directory).registry
          declared = registry.world("QualityControl")&.for_verb(PushDueReader::VERB)
          limits = PushDueReader.thresholds(registry)
          ["push nudge", "#{limits[:commits]} commits or #{limits[:hours]} hours", declared ? "world" : "default"]
        rescue StandardError => e
          ["push nudge", "could not be read", first_line(e.message)]
        end
      end
    end
  end
end
