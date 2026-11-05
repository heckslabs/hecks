# frozen_string_literal: true

require "json"
require "hecks/ports/persistence/plugins/era"
require_relative "../../../../shape_ledger"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        # What a boot of each bluebook under a domain directory would resolve, answered by
        # `Runtime::RevisionStatus`, the resolution the boot itself records, against the database
        # each
        # bluebook's own world declares. Both queries only read: the connection refuses writes.
        module BootStatus
          # Each bluebook's boot status: from its own database when it declares one, else from the
          # committed ledger and its edges (`source` says which).
          #
          # @param domain [Hash, String] the domain directory
          # @return [Hash] `text:` the status as JSON, one row per bluebook
          # @raise [Runtime::NotFound] if the directory cannot be loaded or a database refuses
          def boot_status(domain:)
            answering do
              directory = plain(domain)
              registry = Hecks.describe(directory).registry
              JSON.pretty_generate(with_ledger(directory, registry, Runtime::RevisionStatus.rows(registry, directory)))
            end
          end

          # What a boot would resolve for each bluebook, from its own database only: status, held
          # and current labels, the ordinal it reads, and the reason. A bluebook bound to a store
          # that holds no eras answers `no_eras`.
          #
          # @param domain [Hash, String] the domain directory
          # @return [Hash] `text:` the resolution as JSON, one row per bluebook
          # @raise [Runtime::NotFound] if the directory cannot be loaded or a database refuses
          def boot_resolution(domain:)
            answering do
              directory = plain(domain)
              rows = Runtime::RevisionStatus.rows(Hecks.describe(directory).registry, directory)
              JSON.pretty_generate({ "domain" => directory, "bluebooks" => rows })
            end
          end

          private

          # The rows, with each `no_eras` row answered by the ledger instead.
          def with_ledger(directory, registry, rows)
            ledger = ShapeLedger::Status.of(directory, registry: registry)["bluebooks"] if no_database?(rows)
            bluebooks = rows.to_h { |name, row| [name, row["source"] == "none" ? ledger.fetch(name, row) : row] }
            { "domain" => directory, "bluebooks" => bluebooks }
          end

          def no_database?(rows) = rows.each_value.any? { |row| row["source"] == "none" }
        end
      end
    end
  end
end
