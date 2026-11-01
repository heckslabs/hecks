# frozen_string_literal: true

require "json"
require_relative "../../../../shape_ledger"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # The boot status of each bluebook under a domain directory, read from the committed ledger
        # and its edges. It opens no store, so it answers the same with or without a database.
        module BootStatus
          # @param domain [Hash, String] the domain directory
          # @return [Hash] `text:` the status as JSON, one row per bluebook
          # @raise [Runtime::NotFound] if the directory cannot be loaded
          def boot_status(domain:)
            answering { JSON.pretty_generate(ShapeLedger::Status.of(plain(domain))) }
          end
        end
      end
    end
  end
end
