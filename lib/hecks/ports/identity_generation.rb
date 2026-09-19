require_relative "../runtime/registry"

module Hecks
  module Ports
    # A creating command with no natural key needs a value from
    # somewhere to be its identity — this is that somewhere. Resolved
    # the same way `Ports::Extraction` resolves its own adapter (one
    # adapter registry-wide implements this port, not a per-aggregate
    # binding the way persistence needs — different aggregates have no
    # real reason to want different id-generation strategies within
    # one running app).
    #
    # Replay needs no suppression here, on purpose. A UUID minted for a
    # creating command's identity gets baked into that step's own args
    # — an ordinary string value — the moment it's generated, by
    # whoever issues the first, live dispatch. A recorded corpus
    # script or a captured fuzz-replay step already holds that
    # concrete value; replaying it calls `dispatch` with the same
    # args, and this module is never consulted again, for the same
    # reason `SecureRandom.uuid` never runs twice for one
    # already-recorded step today. `Event#occurred_at`
    # (`command_rules/emission.rb`) is the one other "environmental
    # fact, not caller-supplied" this codebase has, and it's handled
    # the identical way: it fires on every dispatch, replay included,
    # and comparison simply excludes it.
    module IdentityGeneration
      NAME = "identity_generation".freeze

      module_function

      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @return [String] a newly-minted identity value
      def uuid(registry) = adapter(registry).uuid

      # Finds the single adapter bound to this port.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @return [Class] the adapter class implementing this port
      # @raise [Runtime::WiringError] if zero or more than one adapter implements it
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }

        case implementations.size
        when 1 then registry.adapter_class(implementations.first.name)
        when 0
          raise Runtime::WiringError,
                "no adapter implements the #{NAME} port — nothing can mint an identity"
        else
          raise Runtime::WiringError,
                "#{implementations.size} adapters implement the #{NAME} port " \
                "(#{implementations.map(&:name).sort.join(', ')}) — the runtime will not choose for you"
        end
      end
    end
  end
end
