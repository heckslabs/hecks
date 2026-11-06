# frozen_string_literal: true

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The store a plan reads: a connection that refuses every write, nothing provisioned, and
          # a lineage over it that names no era. No temporary database or table is made.
          module Store
            module_function

            # @param held [HeldDomain] the loaded domain
            # @yield [Lineage, PG::Connection] the read-only lineage and its connection
            # @return [Object] the block's value
            # @raise [Runtime::WiringError] if the connection is refused
            def reading(held)
              db = PostgresRevisions.connect_for(held.domain_name, held.settings, provision: false)
              db.exec("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY")
              yield lineage_over(db, held), db
            ensure
              db&.close
            end

            def lineage_over(db, held)
              bluebook = held.bluebook
              PostgresRevisions::Lineage.new(db, bluebook.name, formerly_known_as: bluebook.formerly_known_as, reading: true)
            end
          end
        end
      end
    end
  end
end
