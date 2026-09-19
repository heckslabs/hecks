require_relative "../runtime/registry"

module Hecks
  module Ports
    # Which value a creating command's own identity field gets, when
    # neither a slug-from-another-field nor a sequence-with-prefix
    # mechanically answers it — a driving app's own console, say,
    # falls back to this when a collection's identity strategy names
    # "port" rather than "slug"/"sequence" (both of those stay pure
    # config-driven mechanics, computed by whoever is dispatching,
    # never by this port).
    #
    # Pure delegation, same as every sibling port (AccessControl,
    # IdentityGeneration): an app's own domain declares what "port"
    # actually means for it — mint a real UUID via
    # Ports::IdentityGeneration, derive something else entirely — this
    # port just resolves the one adapter that domain wired and calls
    # it, the same "one adapter registry-wide, refuse if zero or many"
    # resolution every other port here already uses.
    module IdentityAssignment
      NAME = "identity_assignment".freeze

      module_function

      # Asks the domain's adapter which value a creating command's identity field gets.
      #
      # No adapter, spec double or caller of this port ships in this repository, so every
      # shape below other than `registry` is adapter-defined: the port forwards it untouched.
      #
      # @param registry [Runtime::Registry] the booted registry, used to resolve the adapter
      #   and handed on to it
      # @param agg_name [Object] adapter-defined, forwarded unchanged; names the aggregate
      #   whose identity field is being assigned
      # @param field_name [Object] adapter-defined, forwarded unchanged; names the identity
      #   field
      # @param args [Object] adapter-defined, forwarded unchanged; the creating command's own
      #   arguments
      # @return [Object] adapter-defined value to assign as the identity
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      #   (see `adapter`)
      def assign(registry, agg_name:, field_name:, args:)
        adapter(registry).assign(registry, agg_name: agg_name, field_name: field_name, args: args)
      end

      # Finds the single adapter bound to this port, refusing an ambiguous wiring.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Module] the adapter module or class implementing this port
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements this port,
      #   or the one that does has no Ruby implementation under `Hecks::Adapters`
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
