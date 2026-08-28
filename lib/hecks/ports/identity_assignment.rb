require_relative "../runtime/registry"

module Hecks
  module Ports
    # WHICH VALUE A CREATING COMMAND'S OWN IDENTITY FIELD GETS, when
    # neither a slug-from-another-field nor a sequence-with-prefix
    # mechanically answers it — a driving app's own console, say,
    # falls back to this when a collection's identity strategy names
    # "port" rather than "slug"/"sequence" (both of those stay pure
    # config-driven mechanics, computed by whoever is dispatching,
    # never by this port).
    #
    # Pure delegation, same as every sibling port (AccessControl,
    # IdentityGeneration): an app's own domain declares what "port"
    # actually MEANS for it — mint a real UUID via
    # Ports::IdentityGeneration, derive something else entirely — this
    # port just resolves the one adapter that domain wired and calls
    # it, the same "one adapter registry-wide, refuse if zero or many"
    # resolution every other port here already uses.
    module IdentityAssignment
      NAME = "identity_assignment"

      module_function

      def assign(registry, agg_name:, field_name:, args:)
        adapter(registry).assign(registry, agg_name: agg_name, field_name: field_name, args: args)
      end

      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can assign an identity"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
