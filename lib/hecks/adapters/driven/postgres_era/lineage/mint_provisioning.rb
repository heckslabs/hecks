require_relative "../field_cache_provisioner"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The read side of an era that the mint path provisions: each aggregate's head view and the
        # field caches its queries narrow by. The mint that compiles an era and the first-era hold
        # call these; nothing a boot reads does.
        module MintProvisioning
          # Creates and backfills one aggregate's field caches for an era, on this lineage's
          # connection, so the caches commit with the era that owns them.
          #
          # @param aggregate [Bluebook::Aggregate] the aggregate whose where-fields are cached
          # @param era [Integer] the ordinal of the era the caches belong to
          # @return [Hash{String => String}] each cached field mapped to its cache table
          # @raise [PG::Error] if Postgres refuses the DDL, a source read or an upsert
          def provision_read_side!(aggregate, era)
            FieldCacheProvisioner.new(self, aggregate, era).provision!
          end

          # Holds the read side of the first era: each aggregate's head view over the snapshot the
          # first era holds, then its field caches.
          #
          # @param aggregates [Array<Bluebook::Aggregate>] the domain's aggregates
          # @return [void]
          # @raise [PG::Error] if Postgres refuses a statement
          def provision_first_era!(aggregates)
            aggregates.each do |aggregate|
              ensure_first_head!(aggregate.storage_name)
              provision_read_side!(aggregate, 1)
            end
          end
        end
      end
    end
  end
end
