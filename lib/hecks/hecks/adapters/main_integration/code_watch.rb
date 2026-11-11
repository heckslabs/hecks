# frozen_string_literal: true

require "hecks/adapters/driving/resident/fingerprint"

module Hecks
  module Adapters
    class MainIntegration
      # Whether the code this process loaded is still the code on disk. A Ruby process keeps the
      # code it started with, so an advance that outlived a landing would run its remaining steps
      # on code a fix has already replaced. The watch holds the checkout's fingerprint (the one a
      # resident retires on) from the process's first advance and answers whether it has changed,
      # and stays changed once it has: the advance ends and the next one loads the current code.
      class CodeWatch
        # The checkout the adapter's code was loaded from, found from this file and not from the
        # working directory, since the push train runs from a copy of its own.
        ROOT = File.expand_path("../../../../..", __dir__)

        class << self
          # Replaces the fingerprint the process's watch reads; a spec stands in, nil restores the
          # checkout's own.
          #
          # @param fingerprint [#current, nil]
          # @return [void]
          def fingerprint=(fingerprint)
            @fingerprint = fingerprint
            @shared = nil
          end

          # @return [CodeWatch] the process's watch, started by its first use
          def shared = @shared ||= new(@fingerprint || Driving::Resident::Fingerprint.new(ROOT))
        end

        # @param fingerprint [#current] the value that differs whenever the loaded code's files do
        def initialize(fingerprint)
          @fingerprint = fingerprint
          @from = fingerprint.current
          @to = nil
        end

        # @return [Boolean] whether the code has changed since the watch started
        def moved?
          @to ||= changed_value
          !@to.nil?
        end

        # @return [String] the line an advance that stopped for a change reports
        def report = "advance restarted: code changed from #{label(@from)} to #{label(@to)}"

        private

        def changed_value
          now = @fingerprint.current
          now == @from ? nil : now
        end

        def label(value) = value.is_a?(Integer) ? format("%08x", value & 0xffffffff) : value.to_s
      end
    end
  end
end
