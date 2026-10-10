require_relative "errors"
require_relative "routing"
require_relative "invocation_facts"
require_relative "../rendering"

module Hecks
  module Runtime
    # Builds an Invocation from the shapes a caller can dispatch: the receiver, the offered
    # facts, and the command or operation that declares them. Extended onto {Invocation}.
    module InvocationBuilder
      include InvocationFacts

      # What one `from_call` was asked for, handed to the builder for its receiver shape.
      Call = Struct.new(:verb, :to, :with, :flat, :entity_depth, :aggregate, :declaring)
      private_constant :Call

      # Builds an Invocation for one of three call shapes (:aggregate,
      # :entity, :port). Each checks its own parts in a fixed order, because
      # a malformed call's refusal depends on that order; `declaring` is
      # called exactly once, at that shape's point in the order below.
      # rubocop:disable-next Metrics/ParameterLists -- the public keyword entry point every dispatch calls
      def from_call(verb, to:, with:, flat:, receiver: :aggregate, entity_depth: 0, aggregate: nil, &declaring)
        call = Call.new(verb, to, with, flat, entity_depth, aggregate, declaring)
        case receiver
        when :aggregate then aggregate_call(call)
        when :entity then entity_call(call)
        when :port then port_call(call)
        else
          raise ArgumentError, "unknown receiver #{receiver.inspect}"
        end
      end

      # `to` as a `Routing::Envelope`, or nil when no `to:` was given.
      def route(to, entity_depth: 0)
        return nil if to.nil?

        aggregate, entities = to.is_a?(Hash) ? envelope_hash(to) : scalar_envelope(to)

        refuse_malformed_route!(aggregate, entities, entity_depth)
        Routing::Envelope.new(aggregate: aggregate, entities: entities)
      end

      private

      def aggregate_call(call)
        command = call.declaring.call
        facts   = facts_for(command, with: call.with, flat: call.flat)
        new(verb: call.verb, target: route(call.to), facts: facts)
      end

      def entity_call(call)
        target  = route(call.to, entity_depth: call.entity_depth)
        command = call.declaring.call
        new(verb: call.verb, target: target, facts: facts_for(command, with: call.with, flat: call.flat))
      end

      def port_call(call)
        operation = call.declaring.call
        flat      = call.flat.dup
        target    = route(port_receiver(operation, call.aggregate, call.to, flat))
        raise TypeMismatch, "#{operation.hecks_name} requires its receiving aggregate in to:" unless target

        new(verb: call.verb, target: target, facts: facts_for(operation, with: call.with, flat: flat))
      end

      # A Reference-typed attribute naming the owning aggregate is routing,
      # not a fact: lifted out of the flat facts into `to:` when no `to:`
      # was given. Only `.first` of a composite identity is used — no
      # domain in the corpus needs more for a port operation.
      def port_receiver(operation, aggregate, to, flat)
        return to unless to.nil?

        identity = operation.identity_attribute(aggregate.hecks_name)
        return flat.delete(identity.name) if identity && flat.key?(identity.name)
        return to unless operation.to == aggregate.hecks_name

        head_identity(aggregate, flat)
      end

      def head_identity(aggregate, flat)
        identity_name = Array(aggregate.identified_by).first
        flat[identity_name] if identity_name && flat.key?(identity_name)
      end

      def refuse_malformed_route!(aggregate, entities, entity_depth)
        raise TypeMismatch, "to: must name the receiving aggregate identity" if aggregate.nil? || aggregate.to_s.empty?

        refuse_wrong_depth!(entities, entity_depth)
        return unless entities.any? { |identity| identity.nil? || identity.to_s.empty? }

        raise TypeMismatch, "to: contains a blank entity identity"
      end

      def refuse_wrong_depth!(entities, entity_depth)
        return if entities.size == entity_depth

        raise TypeMismatch,
              "to: for an entity command needs #{entity_depth} entity " \
              "#{entity_depth == 1 ? "identity" : "identities"} after the aggregate — got #{entities.size}"
      end

      # Must be a String, matching Rust's own parity check for `to:` — this
      # keeps a same-named `to` attribute from being stolen as the
      # aggregate identity by a flat-facts dispatch.
      def scalar_envelope(to)
        return [to, []] if to.is_a?(String)

        raise TypeMismatch, "to: must be a string aggregate identity or an entity route, got #{Rendering.describe(to)}"
      end

      def envelope_hash(to)
        hash = to.transform_keys(&:to_sym)
        unknown = hash.keys - %i[aggregate entity entities]
        raise TypeMismatch, "to: does not recognize #{unknown.sort.join(", ")}" unless unknown.empty?

        [hash[:aggregate], entity_identities(hash)]
      end

      # An entity route naming no entity is refused here, unconditionally,
      # before entity_depth is checked — otherwise a depth-0 (aggregate)
      # command would let the degenerate `entities: []` Hash slip through.
      def entity_identities(hash)
        raise TypeMismatch, "to: takes entity: or entities:, not both" if hash.key?(:entities) && hash.key?(:entity)

        identities = hash.key?(:entities) ? Array(hash[:entities]) : Array(hash[:entity])
        raise TypeMismatch, "to: entity route requires at least one entity identity" if identities.empty?

        identities
      end
    end
  end
end
