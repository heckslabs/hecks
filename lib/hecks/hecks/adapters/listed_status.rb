# frozen_string_literal: true

module Hecks
  module Adapters
    # Reads one fact of a `claude agents --json` entry that more than one adapter judges.
    #
    # A session that ended its turn is listed with status `idle` while its state still reads
    # `working`; the status is the one that says whether it runs.
    module ListedStatus
      # @param entry [Hash] the session as `claude agents --json` lists it
      # @return [Boolean] whether the listing says the session is idle, whatever its state says
      def self.idle?(entry) = entry["status"].to_s == "idle"
    end
  end
end
