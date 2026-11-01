require_relative "../sql_query_builder"
require_relative "dialect"

module Hecks
  module Adapters
    class PostgresEra
      # Creates and backfills one aggregate's field caches for one era. Only the mint path that
      # compiles an era's head, and the first-era hold, run it; a boot reads the caches that exist.
      class FieldCacheProvisioner
        include SqlQueryBuilder
        include Dialect

        # @param lineage [Lineage] the owner lineage whose connection the caches are written on
        # @param aggregate [Bluebook::Aggregate] the aggregate whose where-fields are cached
        # @param era [Integer] the ordinal of the era the caches belong to
        def initialize(lineage, aggregate, era)
          @lineage = lineage
          @aggregate = aggregate
          @era = era
        end

        # Names the aggregate in storage, as the adapter's `table` does.
        #
        # @return [String] the aggregate's snake_case storage name
        def table = @aggregate.storage_name

        # Creates each cached where-field's table if missing, then backfills it from the era's head.
        #
        # @return [Hash{String => String}] each cached field mapped to its cache table's name
        # @raise [PG::Error] if Postgres refuses the DDL, a source read or an upsert
        def provision!
          cached_where_fields.to_h do |field|
            [field, @lineage.ensure_field_cache!(table, @era, field, query_expression(field))]
          end
        end
      end
    end
  end
end
