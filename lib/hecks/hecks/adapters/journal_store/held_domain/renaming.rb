# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      class HeldDomain
        # How a held domain reaches the journal store to rename it: with its former name known,
        # and nothing provisioned.
        module Renaming
          # Connects to the journal store and yields a lineage that knows the domain's former name,
          # with nothing provisioned: the rename moves what is there and builds nothing, and a
          # database that holds no eras is left as it is. A role that bypasses the write fence is
          # refused unless the world allows it.
          #
          # @yield [Lineage] the domain's lineage, with `formerly_known_as` set
          # @return [Object] the block's value
          # @raise [Runtime::WiringError] on a superuser connection the world has not allowed
          def renaming
            db = PostgresEra.connect_for(bluebook.name, settings, provision: false)
            lineage = PostgresEra::Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as)
            lineage.check_fence_applies!(allow_superuser: PostgresEra.setting(settings, :allow_superuser, default: false))
            yield lineage
          ensure
            db&.close
          end

          # The where-fields each aggregate's queries narrow by, whose cache tables hash the
          # domain's name and so are renamed with it. A superset of the fields actually cached:
          # a table that does not exist is skipped.
          #
          # @return [Hash{String => Array<String>}] storage name to field names
          def cache_fields
            aggregates.to_h do |aggregate|
              queries = aggregate.queries + aggregate.entities.flat_map(&:queries)
              [aggregate.storage_name, queries.flat_map { |query| query.wheres.map { |clause| clause.field.to_s } }.uniq]
            end
          end

          # @return [String, nil] the name the domain was known by before its rename
          def former_name = bluebook.formerly_known_as
        end
      end
    end
  end
end
