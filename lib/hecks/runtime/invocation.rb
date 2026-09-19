require_relative "errors"
require_relative "refusal_wording"
require_relative "routing"
require_relative "../rendering"

module Hecks
  module Runtime
    # **One dispatch, as data** — the verb, the receiver it is addressed to
    # (`target`, a `Routing::Envelope` or nil), and every fact the caller did
    # or did not offer. Built once per dispatch by `Invocation.from_call`, the
    # only place the runtime interprets the shape of a call (`to:` vs `with:`
    # vs the flat facts hash `dispatch_flat` carries, a port operation's
    # reference attribute
    # lifted into `to:`). `Runtime::Routing.envelope`/`.payload` delegate here
    # and no longer hold that logic themselves.
    #
    # `facts` maps a fact name to exactly one of:
    #
    #   - `Invocation::Absent`  — the key was never offered (every declared
    #                             attribute the caller left out appears so)
    #   - `Invocation::Null`    — the key was offered with an explicit nil
    #   - `Invocation::Present` — the key was offered with a value
    #
    # Keys are kept exactly as offered: `with:` keys are symbolized (as they
    # always were), a flat facts hash keeps whatever key the wire used. Undeclared keys a caller
    # offered are kept too — refusing them is
    # still `refuse_unknown_arguments`' job, a dispatch step, not this one.
    #
    # I1 changes no behavior: every interpreter still reads `ctx.args`,
    # which is `#to_args` — the same Hash `Routing.payload` returns.
    # Roadmap I2 moves the Ruby `decode_arguments` step onto `facts` itself.
    Invocation = Data.define(:verb, :target, :facts)

    # The fact markers, the fact readers, and `from_call` — see above.
    class Invocation
      # A fact the caller offered with a real (non-nil) value.
      Present = Data.define(:value) do
        def inspect = "#<Invocation::Present #{value.inspect}>"
        alias_method :to_s, :inspect
      end

      # The class of the two frozen marker singletons below — never
      # instantiated anywhere else.
      class Marker
        # @param name [String] the marker's own label, used by #inspect/#to_s
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

      # @param verb [String] the fully qualified verb this invocation dispatches
      # @param target [Routing::Envelope, nil] the resolved receiver, or nil when
      #   the facts carry the identity themselves
      # @param facts [Hash{String, Symbol => Object}] every candidate fact, keyed by
      #   offered (or declared) name; frozen, deep-duped, before being stored
      def initialize(verb:, target:, facts:)
        super(verb: verb, target: target, facts: facts.dup.freeze)
      end

      # Reads the fact recorded under `name`.
      #
      # The fact recorded under `name` — `Absent` for a name never offered
      # and never declared either.
      #
      # @param name [String, Symbol] the fact name to look up
      # @return [Invocation::Present, Invocation::Null, Invocation::Absent] the
      #   recorded marker for `name`
      def fact(name) = facts.fetch(name, Absent)

      # Reports whether `name` was offered with a real, non-nil value.
      #
      # @param name [String, Symbol] the fact name to check
      # @return [Boolean] true if `name` was offered with a non-nil value
      def present?(name) = fact(name).is_a?(Present)

      # Reports whether `name` was offered with an explicit nil.
      #
      # @param name [String, Symbol] the fact name to check
      # @return [Boolean] true if `name` was offered with an explicit nil
      def null?(name)    = fact(name).equal?(Null)

      # Reports whether `name` was never offered.
      #
      # @param name [String, Symbol] the fact name to check
      # @return [Boolean] true if `name` was never offered (and, if declared, left out)
      def absent?(name)  = fact(name).equal?(Absent)

      # A Present fact's value; nil for an explicit Null. Raises KeyError for
      # an Absent fact — "never offered" has no value, and answering nil
      # would re-conflate it with an explicit null, the very ambiguity this
      # type exists to remove. Ask `absent?`/`present?` first.
      #
      # @param name [String, Symbol] the fact name to read
      # @return [Object, nil] the offered value; nil for an explicit Null fact
      # @raise [KeyError] if `name` names an Absent fact (never offered)
      def value(name)
        case (found = fact(name))
        when Present then found.value
        when Null then nil
        else raise KeyError, "#{verb} was not given #{name.inspect}"
        end
      end

      # The flat args hash, byte for byte what `Routing.payload` returned
      # before this type existed: offered keys in offered order, Absent keys
      # omitted, Null keys mapped to nil. A fresh Hash every call.
      #
      # @return [Hash{String, Symbol => Object}] the offered facts by name; a fact
      #   offered as nil is kept as nil
      def to_args
        facts.each_with_object({}) do |(name, found), args|
          next if found.equal?(Absent)

          args[name] = found.equal?(Null) ? nil : found.value
        end
      end

      class << self
        # The one reading of a call's shape. `receiver:` picks which of the
        # three dispatch shapes this is, because each has always checked its
        # parts in its own order and a malformed call's refusal depends on
        # that order:
        #
        #   :aggregate — facts first (`with:` checks), then `to:`
        #   :entity    — `to:` first, then the block (which resolves the
        #                entity chain, UnknownVerb), then facts
        #   :port      — a reference attribute / identity field lifted into
        #                `to:`, then `to:` (which a port operation requires),
        #                then facts
        #
        # The block answers the declaring command or port operation (anything
        # with `hecks_name` and `attributes`); it is called exactly once, at
        # the point in that order where the caller always resolved it.
        # `aggregate:` is the owning aggregate construct, read for `:port`
        # only.
        #
        # @param verb [String] the fully qualified verb being dispatched
        # @param to [String, Hash, nil] a bare aggregate identity, or a Hash with
        #   `aggregate:` and `entity:`/`entities:`; nil for no explicit receiver
        # @param with [Hash, nil] the command's facts, keyed by attribute name; nil
        #   when the caller offers `flat` instead
        # @param flat [Hash] the command's facts as a flat args hash, used when `with`
        #   is nil; for `:port`, may also carry the receiver identity under a
        #   reference attribute's own name
        # @param receiver [Symbol] which of the three dispatch shapes this is:
        #   `:aggregate`, `:entity` or `:port`
        # @param entity_depth [Integer] the number of entity-hop identities `to:`
        #   must carry, for `:entity` only
        # @param aggregate [Bluebook::Aggregate, nil] the owning aggregate construct,
        #   read for `:port` only
        # @yieldreturn [Class] the declaring command or port-operation class (anything
        #   with `hecks_name` and `attributes`)
        # @return [Runtime::Invocation] the built invocation
        # @raise [Runtime::TypeMismatch] if `to:` is malformed, its entity count is
        #   wrong, or (`:port` only) the operation resolves no receiving aggregate
        # @raise [Runtime::UnknownArgument] if `with:` names an attribute the command
        #   does not declare
        # @raise [Runtime::AbsentArgument] if `with:` omits a required attribute
        # @raise [ArgumentError] if `receiver` is none of `:aggregate`, `:entity` or `:port`
        def from_call(verb, to:, with:, flat:, receiver: :aggregate, entity_depth: 0, aggregate: nil, &declaring)
          case receiver
          when :aggregate
            command = declaring.call
            facts   = facts_for(command, with: with, flat: flat)
            new(verb: verb, target: route(to), facts: facts)
          when :entity
            target  = route(to, entity_depth: entity_depth)
            command = declaring.call
            new(verb: verb, target: target, facts: facts_for(command, with: with, flat: flat))
          when :port
            port_call(verb, aggregate, declaring.call, to: to, with: with, flat: flat)
          else
            raise ArgumentError, "unknown receiver #{receiver.inspect}"
          end
        end

        # `to:` as a `Routing::Envelope`, or nil when no `to:` was given.
        #
        # @param to [String, Hash, nil] a bare aggregate identity, or a Hash with
        #   `aggregate:` and `entity:`/`entities:`; nil for no receiver
        # @param entity_depth [Integer] the number of entity-hop identities `to`
        #   must carry
        # @return [Routing::Envelope, nil] the resolved envelope, or nil when `to`
        #   is nil
        # @raise [Runtime::TypeMismatch] if `to` is malformed, or its entity count
        #   does not match `entity_depth`
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

        # The offered facts for `declaring`, as Absent/Null/Present — offered
        # keys first, in offered order, then every declared attribute that was
        # not offered, as Absent.
        #
        # @param declaring [Class] the command or port-operation class (anything
        #   with `hecks_name` and `attributes`) whose declared attributes are read
        # @param with [Hash, nil] the command's facts, keyed by attribute name; nil
        #   when the caller offers `flat` instead
        # @param flat [Hash] the command's facts as a flat args hash, used when `with`
        #   is nil
        # @return [Hash{String, Symbol => Invocation::Absent, Invocation::Null,
        #   Invocation::Present}] each candidate fact keyed by its offered (or
        #   declared) name
        # @raise [Runtime::TypeMismatch] if both `with` and a non-empty `flat` are
        #   given, or if `with` is not a Hash
        # @raise [Runtime::UnknownArgument] if `with:` names an attribute `declaring`
        #   does not declare
        # @raise [Runtime::AbsentArgument] if `with:` omits a required attribute
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

        # **The port operation shape** — moved from `Dispatcher#port_invocation`.
        #
        # A Reference-typed attribute naming the owning aggregate is routing,
        # not a fact: lifted out of the flat facts into `to:` when no `to:`
        # was given. A `to:`-declared operation carries no Reference
        # attribute at all (PortOperationBuilder#initialize's own comment),
        # so its receiver is read — not removed — from the plain attribute
        # named for the owner's first `identified_by` field: that attribute
        # is still a declared external fact `refuse_absent_arguments`
        # expects to find (Rust's own comment: "declare only external facts
        # with attribute"; a real AbsentArgument confirmed this before `[]`
        # replaced `delete`). Composite identity is not attempted — `.first`
        # only, no domain in the corpus needs more for a port operation.
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

        # BUG#7 — a non-Hash `to:` must be a String, matching Rust's
        # `RoutingEnvelope::from_json` (kernel/routing.rs), which refuses
        # anything neither a JSON string nor object before the domain payload
        # is examined. Surfaced on `examples/roster`'s `Mark`, whose own
        # attribute is literally named `to`: a flat-facts dispatch steals
        # that key into this parameter, and without this check an out-of-range
        # Integer would be accepted as the aggregate identity, leaving Mark's
        # `to` fact absent (AbsentArgument in Ruby, TypeMismatch in Rust). See
        # spec/runtime/routing_envelope_shape_spec.rb.
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

        # BUG#18 — an entity route naming no entity (`entities: []`, or
        # neither key) refuses here, unconditionally, before entity_depth is
        # consulted: for an aggregate-level command (depth 0), without this,
        # `[].size == 0` would satisfy the depth check and let the degenerate
        # Hash reach the command's own validation. Rust's `RoutingEnvelope::
        # from_json` always refused it at this point. A bare aggregate identity
        # String remains the ordinary aggregate-command shape.
        def entity_identities(hash)
          raise TypeMismatch, "to: takes entity: or entities:, not both" if hash.key?(:entities) && hash.key?(:entity)

          identities = hash.key?(:entities) ? Array(hash[:entities]) : Array(hash[:entity])
          raise TypeMismatch, "to: entity route requires at least one entity identity" if identities.empty?

          identities
        end

        # `with:` is deliberately strict: a caller choosing the explicit
        # envelope cannot smuggle receiver identity back into the payload,
        # and may not mix it with a flat facts hash. Without `with:`
        # (nil or false) the flat facts are the facts, unread —
        # whether `to:` was given never enters this decision (BUG#17).
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

        def refuse_absent_facts!(declaring, offered, declared)
          absent = declaring.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym } - offered.keys
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
