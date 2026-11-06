module Hecks
  module Adapters
    # The plain Postgres store, reopened to route its storage calls through a layout.
    class Postgres
      # The storage layout a `Postgres` adapter reads and writes through (ADR 0182). The table
      # layout is the plain one-table-per-aggregate store this file's siblings implement; the
      # adapter forwards each storage call to its layout, so a second layout can take the same
      # calls without the adapter changing shape.
      module Layout
        # The storage and connection calls a layout answers. Schema and dialect helpers stay on the
        # adapter: every layout shares them.
        STORAGE = %i[
          append entries events events_for record_event find all count project reset! save
          delete atomic_put execute_query decode query
          save_saga delete_saga each_saga
          transaction transaction_status exec exec_params pg_exec pg_exec_params backend_pid
          reconnect! dead? close disown! dispatch_claim dispatch_applied? outbox_claim outbox_enqueue
          outbox_settle outbox_rows outbox_row_from insert_outbox_row create_outbox_table!
        ].freeze

        # Runs the adapter's own implementation of a storage call, skipping the forwarding
        # method the adapter defines for it.
        #
        # **Why the lookup skips the class:** the adapter's class body forwards each call to
        # its layout, so the implementation lives in one of the modules the class includes.
        module Implementations
          # @param name [Symbol] a storage call from {Layout::STORAGE}
          # @return [UnboundMethod] the module method that implements the call
          def self.for(name)
            Postgres.ancestors.drop(1).each do |mod|
              return mod.instance_method(name) if mod.method_defined?(name, false) || mod.private_method_defined?(name, false)
            end
            raise NoMethodError, "no table implementation for #{name}"
          end
        end

        # The table layout: the plain store, one table per aggregate.
        #
        # Each call runs the adapter's implementation against the adapter's own connection, so the
        # table layout's behaviour is unchanged from before the seam existed.
        class Table
          # @param adapter [Postgres] the adapter whose connection and state the calls use
          def initialize(adapter)
            @adapter = adapter
          end

          STORAGE.each do |name|
            define_method(name) do |*args, **kwargs, &block|
              Implementations.for(name).bind_call(@adapter, *args, **kwargs, &block)
            end
          end
        end
      end

      # The class that holds the revision layout, which the era tools reach through the adapter.
      #
      # @return [Class] the revision store class
      def self.revision_store_class = Layout::Revisions.store_class

      def self.prepare_hecksagon(hecksagon)
        revision_store_class if hecksagon.revisions?
      end

      # The layout the adapter's storage calls are forwarded to.
      #
      # @return [Layout::Table] the table layout, bound to this adapter
      def layout = @layout ||= Layout::Table.new(self)

      Layout::STORAGE.each do |name|
        define_method(name) do |*args, **kwargs, &block|
          layout.public_send(name, *args, **kwargs, &block)
        end
      end
    end
  end
end
