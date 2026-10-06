require_relative "errors"
require_relative "refusal_wording"
require_relative "routing"
require_relative "../rendering"

module Hecks
  module Runtime
    # One dispatch, as data: the verb, the resolved receiver (`target`, a
    # `Routing::Envelope` or nil), and every fact the caller offered or didn't.
    Invocation = Data.define(:verb, :target, :facts)

    # Adds the fact wrappers and builders for an `Invocation`.
    class Invocation
      # A fact the caller offered with a real (non-nil) value.
      Present = Data.define(:value) do
        def inspect = "#<Invocation::Present #{value.inspect}>"
        alias_method :to_s, :inspect
      end

      # The class of the two frozen marker singletons below — never
      # instantiated anywhere else.
      class Marker
        def initialize(name)
          @name = name
          freeze
        end

        def inspect = "Invocation::#{@name}"
        alias to_s inspect
      end
      private_constant :Marker

      Absent = Marker.new("Absent")
      Null   = Marker.new("Null")

      # Dupes and freezes `facts` so a caller can't mutate them after
      # construction.
      def initialize(verb:, target:, facts:)
        super(verb: verb, target: target, facts: facts.dup.freeze)
      end

      # The fact recorded under `name`; `Absent` when never offered (and not
      # declared either).
      def fact(name) = facts.fetch(name, Absent)

      def present?(name) = fact(name).is_a?(Present)

      def null?(name)    = fact(name).equal?(Null)

      def absent?(name)  = fact(name).equal?(Absent)

      # A Present fact's value (nil for Null). Raises for Absent rather than
      # returning nil, so "never offered" isn't conflated with an explicit null.
      def value(name)
        case (found = fact(name))
        when Present then found.value
        when Null then nil
        else raise KeyError, "#{verb} was not given #{name.inspect}"
        end
      end

      # The offered facts as a plain Hash, in offered order: Absent keys
      # omitted, Null mapped to nil. A fresh Hash every call.
      def to_args
        facts.each_with_object({}) do |(name, found), args|
          next if found.equal?(Absent)

          args[name] = found.equal?(Null) ? nil : found.value
        end
      end

      class << self
        # Builds an Invocation for one of three call shapes (:aggregate,
        # :entity, :port). Each checks its own parts in a fixed order, because
        # a malformed call's refusal depends on that order; `declaring` is
        # called exactly once, at that shape's point in the order below.
        def from_call(verb, to:, with:, flat:, receiver: :aggregate, entity_depth: 0, aggregate: nil, &declaring)
          case receiver
          when :aggregate
            command = yield
            facts   = facts_for(command, with: with, flat: flat)
            new(verb: verb, target: route(to), facts: facts)
          when :entity
            target  = route(to, entity_depth: entity_depth)
            command = yield
            new(verb: verb, target: target, facts: facts_for(command, with: with, flat: flat))
          when :port
            port_call(verb, aggregate, yield, to: to, with: with, flat: flat)
          else
            raise ArgumentError, "unknown receiver #{receiver.inspect}"
          end
        end

        # `to` as a `Routing::Envelope`, or nil when no `to:` was given.
        def route(to, entity_depth: 0)
          return nil if to.nil?

          aggregate, entities = to.is_a?(Hash) ? envelope_hash(to) : scalar_envelope(to)

          raise TypeMismatch, "to: must name the receiving aggregate identity" if aggregate.nil? || aggregate.to_s.empty?
          if entities.size != entity_depth
            raise TypeMismatch,
                  "to: for an entity command needs #{entity_depth} entity " \
                  "#{entity_depth == 1 ? 'identity' : 'identities'} after the aggregate — got #{entities.size}"
          end
          raise TypeMismatch, "to: contains a blank entity identity" if entities.any? do |identity|
            identity.nil? || identity.to_s.empty?
          end

          Routing::Envelope.new(aggregate: aggregate, entities: entities)
        end

        # Every candidate fact for `declaring`, as Absent/Null/Present: offered
        # keys first in offered order, then remaining declared attributes as Absent.
        def facts_for(declaring, with:, flat:)
          offered = offered_facts(declaring, with: with, flat: flat)
          facts = offered.each_with_object({}) do |(name, value), found|
            found[name] = value.nil? ? Null : Present.new(value: value)
          end
          declaring.attributes.each do |attribute|
            name = attribute.name.to_sym
            facts[name] = Absent unless facts.key?(name)
          end
          facts
        end

        private

        # A Reference-typed attribute naming the owning aggregate is routing,
        # not a fact: lifted out of the flat facts into `to:` when no `to:`
        # was given. Only `.first` of a composite identity is used — no
        # domain in the corpus needs more for a port operation.
        def port_call(verb, aggregate, operation, to:, with:, flat:)
          flat = flat.dup
          identity = operation.identity_attribute(aggregate.hecks_name)
          if to.nil? && identity && flat.key?(identity.name)
            to = flat.delete(identity.name)
          elsif to.nil? && operation.to == aggregate.hecks_name
            identity_name = Array(aggregate.identified_by).first
            to = flat[identity_name] if identity_name && flat.key?(identity_name)
          end

          target = route(to)
          raise TypeMismatch, "#{operation.hecks_name} requires its receiving aggregate in to:" unless target

          new(verb: verb, target: target, facts: facts_for(operation, with: with, flat: flat))
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
          raise TypeMismatch, "to: does not recognize #{unknown.sort.join(', ')}" unless unknown.empty?

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

        # `with:` is deliberately strict: a caller choosing the explicit
        # envelope cannot smuggle receiver identity back into the payload,
        # and may not mix it with a flat facts hash. Without `with:`, the
        # flat facts are taken as-is, unread.
        def offered_facts(declaring, with:, flat:)
          if with && !flat.empty?
            raise TypeMismatch,
                  "dispatch takes command facts in with:, not both with: and a flat facts hash"
          end

          return flat unless with
          raise TypeMismatch, "with: must be a hash of command facts" unless with.is_a?(Hash)

          offered = with.transform_keys(&:to_sym)
          declared = declaring.attributes.map { |attribute| attribute.name.to_sym }
          refuse_unknown_facts!(declaring, offered, declared)
          refuse_absent_facts!(declaring, offered, declared)
          offered
        end

        # Unknown before absent — a `with:` that is both still refuses
        # UnknownArgument first.
        def refuse_unknown_facts!(declaring, offered, declared)
          unknown = (offered.keys - declared).sort
          return if unknown.empty?

          raise UnknownArgument,
                RefusalWording.render_site("UnknownArgument", "unknown_args",
                                           command: declaring.hecks_name, unknown: unknown,
                                           declared: declared)
        end

        # A fact the command `needs`, and an argument its attribute gives a default, are not absent:
        # the interpreter fills them before any refusal reads the arguments.
        def refuse_absent_facts!(declaring, offered, declared)
          needed = declaring.respond_to?(:needs) ? declaring.needs.map(&:to_sym) : []
          defaulted = declaring.attributes.select { |attribute| attribute.respond_to?(:default) && !attribute.default.nil? }
                               .map { |attribute| attribute.name.to_sym }
          absent = declaring.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym } -
                   offered.keys - needed - defaulted
          return if absent.empty?

          raise AbsentArgument,
                RefusalWording.render_site("AbsentArgument", "absent_args",
                                           command: declaring.hecks_name, absent: absent,
                                           declared: declared)
        end
      end
    end
  end
end
