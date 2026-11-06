module Hecks
  module Adapters
    class Postgres
      module Layout
        # The revision layout (ADR 0182): a domain whose hecksagon sets `revisions true` keeps its
        # eras, lineage and field caches in the `PostgresRevisions` store. This layout holds that store and
        # answers the storage calls with it, so a `Postgres` bind reaches the revision code through
        # the same seam the table layout uses.
        class Revisions
          # @param aggregate [Bluebook::Aggregate] the aggregate the store is built for
          # @param settings [Hash] the binding's settings, as the factory resolved them
          # @param root [String, nil] the project root, as the factory passed it
          def initialize(aggregate:, settings:, root:)
            @store = PostgresRevisions.new(aggregate: aggregate, settings: settings, root: root)
          end

          # The revision store, which owns the lineage and the write lock.
          #
          # @return [PostgresRevisions] the store the calls are answered with
          attr_reader :store

          # The class the revision layout builds its store from.
          #
          # @return [Class] the revision store class
          def self.store_class = PostgresRevisions

          # Runs a block under the revision store's cross-process write lock.
          #
          # @yield the block to run while the lock is held
          # @return [Object] the block's value
          def with_write_lock(&) = @store.with_write_lock(&)

          # The capabilities the revision store implements natively.
          #
          # @return [Array<Symbol>] the store's own persistence capabilities
          def persistence_capabilities = @store.persistence_capabilities

          STORAGE.each do |name|
            define_method(name) do |*args, **kwargs, &block|
              @store.__send__(name, *args, **kwargs, &block)
            end
          end
        end
      end
    end
  end
end
