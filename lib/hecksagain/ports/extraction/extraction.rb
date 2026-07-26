# Extraction — the port's execution : resolve the bound adapter and delegate.
#
# This is the port SIDE of the inverted arrow. The adapter declares the port ;
# the port never names an adapter, so resolution here is a LOOKUP over whatever
# registered itself, never a hardcoded constant.
#
# THE SINGLE-ADAPTER RULE. Persistence binds per aggregate, because a domain
# genuinely wants Sqlite for one root and Memory for another. Extraction has no
# such axis — a bluebook's predicates are recovered one way or they are not
# recovered at all — so when exactly one adapter implements this port, that IS
# the binding and no hecksagon line is required. Two would be an ambiguity the
# runtime cannot resolve for you, and it says so rather than picking.
#
# A registry is REQUIRED. Extraction runs while a bluebook is being read, and a
# bluebook can only be read inside a boot — `Hecks.bluebook` refuses outside one.
# So there is no legitimate caller without a registry, and falling back to a
# default adapter would be a shim covering a bug rather than a convenience.
#
#   Ports::Extraction.canonical(block)  # => "toppings.size < 10"
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
