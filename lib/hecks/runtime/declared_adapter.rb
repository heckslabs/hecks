require_relative "errors"
require_relative "value"
require_relative "../naming"
require_relative "../declared_replies"

module Hecks
  module Runtime
    # The Ruby face of a declared adapter: an `.adapter` that answers its port from `replies` and
    # `refuses` rows instead of naming a Ruby class. The rows are read and answered by
    # `hecks-parse reply`, so this class only carries an asking to it and reads the outcome back.
    #
    # @example An adapter with no code behind it
    #   Hecks.adapter "RecordedCarrier" do
    #     port "Carrier"
    #     replies "Collect", where: { destination: "Lisbon" }, with: { tracking: { value: "LX-1" } }
    #     refuses "Collect", saying: "no carrier reaches that destination"
    #   end
    class DeclaredAdapter
      # Raised when a row refuses the asking, or no row matches it. It is the outside saying no, so
      # an ask records it as the port's `refuses` event and a query refuses with it.
      class Refused < RemoteRefusal; end

      # Each declaration's class, keyed by the declaration itself, so a reloaded file gets its own.
      BUILT = ObjectSpace::WeakMap.new
      BUILT_LOCK = Mutex.new
      private_constant :BUILT, :BUILT_LOCK

      class << self
        # The class that answers for one declared adapter: one public method per ask or query its
        # rows name, snake-cased as the runtime asks it. Built once per adapter.
        #
        # @param adapter [Bluebook::Adapter] an adapter whose `declared?` is true
        # @return [Class] a subclass of {DeclaredAdapter} bound to `adapter`
        def class_for(adapter)
          BUILT_LOCK.synchronize { BUILT[adapter] ||= build_class(adapter) }
        end

        private

        def build_class(adapter)
          Class.new(self) do
            define_singleton_method(:declaration) { adapter }
            adapter.replied_asks.each do |ask|
              define_method(Naming.snake(ask)) { |**asked| answer(ask, asked) }
            end
          end
        end
      end

      # @param context [Hash] the registry and aggregate the runtime offers; a declared adapter
      #   reads neither, since its answer depends on the asking alone
      def initialize(**context)
        @context = context
      end

      # Asks `hecks-parse reply` for this adapter's answer to one asking.
      #
      # @param ask [String] the ask or query, as its rows name it (`"Collect"`)
      # @param asked [Hash] the held state and arguments the runtime hands an adapter, as plain data
      # @return [Hash, Array<Hash>] the declared answer
      # @raise [Refused] when a row refuses or no row matches
      # @raise [WiringError] when the parser cannot read the adapter's file
      def answer(ask, asked)
        outcome = ask_parser(ask, asked)
        raise Refused, outcome.fetch("refused") if outcome.key?("refused")

        Value.deep_symbolize(outcome.fetch("answer"))
      end

      private

      # @return [Bluebook::Adapter] the declaration this instance's class answers for
      def declaration = self.class.declaration

      def ask_parser(ask, asked)
        DeclaredReplies.answer(declaration.source_path, declaration.name, ask, asked)
      rescue DeclaredReplies::Unread => e
        raise WiringError, "#{declaration.name} could not answer #{ask}: #{e.message}"
      end
    end
  end
end
