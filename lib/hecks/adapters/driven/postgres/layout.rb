module Hecks
  module Adapters
    # The plain Postgres store, reopened to route its storage calls through a layout.
    class Postgres
      # The storage layout a `Postgres` adapter reads and writes through (ADR 0182). The table
      # layout is the plain one-table-per-aggregate store this file's siblings implement; the
      # adapter forwards each storage call to its layout, so a second layout can take the same
      # calls without the adapter changing shape.
      module Layout
        # The storage calls a layout answers. Connection, schema and dialect helpers stay on the
        # adapter: every layout shares them.
        STORAGE = %i[
          append entries events events_for record_event find all count project reset! save
          delete atomic_put execute_query decode
        ].freeze

        # Runs the adapter's own implementation of a storage call, skipping the forwarding
        # method the adapter defines for it.
        #
        # **Why the lookup skips the class:** the adapter's class body forwards each call to
        # its layout, so the implementation lives in one of the modules the class includes.
        module Implementations
          # @param name [Symbol] a storage call from {STORAGE}
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
