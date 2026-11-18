# frozen_string_literal: true

require_relative "../console_capture"
require_relative "last_verified"
require_relative "load"
require_relative "../git_shallow_check/switch"

module Hecks
  module Adapters
    class MainIntegration
      # What a landed commit is verified with on this machine after the merge, as the Tickets
      # world's `main_verification` line says in `verifies`: `impacted` (the quick gate and the
      # specs the landings since the last verified commit touch, once the shallow check is off),
      # `quick` (the quick gate only: no impacted specs, no search for a first bad merge, no
      # last-verified marker) or `off` (nothing is run). The setting is read through the world
      # rows at each verification, so a saved value is in force for the next landing. While the
      # shallow check is on it is not read and the verification is what it always was.
      class LocalMode
        # The values the setting takes, and the one a line that names none stands at.
        VALUES = %w[impacted quick off].freeze
        DEFAULT = "impacted"

        # @param repository [Repository] the repository whose checkout and git directory are read
        def initialize(repository)
          @repository = repository
        end

        # @return [String] the mode in force: `impacted` while the shallow check is on
        def value
          return DEFAULT unless shallow_off?

          named = Load.row(@repository.checkout)[:verifies].to_s
          VALUES.include?(named) ? named : DEFAULT
        end

        # @return [Boolean] whether the specs the landings touch run here, after the merge
        def impacted? = shallow_off? && value == DEFAULT

        # @return [Boolean] whether any check runs on a landed commit
        def verifies? = value != "off"

        # @return [Boolean] whether a verified commit is recorded as the last one verified
        def marks? = value != "quick"

        # @return [Boolean] whether a failed verification may search for its first bad merge
        def searches? = value == DEFAULT

        # Records the commit as the last verified one in the git directory, when the mode marks. A
        # marker that cannot be written never fails a verification that passed; the report says so.
        #
        # @param landed [String] the commit verified
        # @return [String] what the report adds: nothing, or why the marker was not written
        def remember(landed)
          LastVerified.write(@repository.common_dir, landed) if marks?
          ""
        rescue SystemCallError => e
          "; last-verified marker not written: #{e.message}"
        end

        # @param landed [String] the commit not verified here
        # @return [String] what the report of a verification says when the setting is `off`: the
        #   run goes on to boarding, and nothing ran and no marker was written
        def unchecked(landed) = "#{landed[0, 10]} not verified here: local verification is off"

        # With the setting at `quick` or `off` no search is made and none is answered, so no episode
        # of the domain's red-main rule starts from a local verification.
        #
        # @raise [ConsoleCapture::Failure] unless the mode searches
        def search!
          return if searches?

          raise ConsoleCapture::Failure, "local verification is #{value}: no search is made"
        end

        private

        def shallow_off? = !GitShallowCheck::Switch.new(@repository.common_dir).on?
      end
    end
  end
end
