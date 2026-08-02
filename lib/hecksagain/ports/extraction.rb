require_relative "../runtime/registry"

module Hecksagain
  module Ports
    module Extraction
      NAME = "extraction"

      module_function

      def canonical(block) = adapter.canonical(block)

      def adapter
        registry = Hecksagain.current_registry
        unless registry
          raise Runtime::WiringError,
                "extraction resolved outside a boot — a predicate can only be " \
                "read while a bluebook is loading"
        end

        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can recover a " \
                "predicate's source"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime " \
                "will not choose for you"
        end
      end
    end
  end
end
