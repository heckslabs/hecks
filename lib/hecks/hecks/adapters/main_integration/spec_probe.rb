# frozen_string_literal: true

require_relative "impacted_check"

module Hecks
  module Adapters
    class MainIntegration
      # Runs named spec files in a clean copy through the launcher, a few files per call, holding
      # one heavy-job place for the whole run as {ImpactedCheck} does. It answers by returning when
      # every file passes and by raising `ConsoleCapture::Failure` naming the failing files when
      # one does not.
      class SpecProbe
        # @param directory [String] the clean copy
        # @param files [Array<String>] the spec files to run
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming each failing file
        def call(directory, files)
          Codebase::HeavySlots.held(directory, ImpactedCheck::JOB) do
            files.each_slice(GitShallowCheck::ImpactedBatch::SIZE) do |batch|
              GitShallowCheck::ImpactedBatch.call(ImpactedCheck::Launched.new, directory, batch)
            end
          end
        end
      end
    end
  end
end
