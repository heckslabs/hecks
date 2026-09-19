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
    # vs loose keyword arguments, a port operation's reference attribute
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
    # always were), loose keyword arguments keep whatever key the caller
    # used. Undeclared keys a caller offered are kept too — refusing them is
    # still `refuse_unknown_arguments`' job, a dispatch step, not this one.
    #
    # PR I1 changes no behavior: every interpreter still reads `ctx.args`,
    # which is `#to_args` — the same Hash shape `Routing.payload` returns.
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
        # @param name [String] the marker's display name, such as `"Absent"` or `"Null"`
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
      # @param target [Routing::Envelope, nil] the `to:` receiver, or nil
      # @param facts [Hash{Symbol => Object}] each fact name mapped to `Absent`, `Null`, or a
      #   `Present`; duplicated and frozen before being stored
      def initialize(verb:, target:, facts:)
        super(verb: verb, target: target, facts: facts.dup.freeze)
      end

      # The fact recorded under `name` — `Absent` for a name never offered
      # and never declared either.
      #
      # @param name [Symbol] the fact name
      # @return [Hecks::Runtime::Invocation::Present, Hecks::Runtime::Invocation::Null,
      #   Hecks::Runtime::Invocation::Absent] the recorded marker
      def fact(name) = facts.fetch(name, Absent)

      # Reports whether the caller offered `name` with a real (non-nil) value.
      #
      # @param name [Symbol] the fact name
      # @return [Boolean] true if `name`'s fact is a `Present`
      def present?(name) = fact(name).is_a?(Present)

      # Reports whether the caller offered `name` with an explicit nil.
      #
      # @param name [Symbol] the fact name
      # @return [Boolean] true if `name`'s fact is `Null`
      def null?(name)    = fact(name).equal?(Null)

      # Reports whether the caller never offered `name` at all.
      #
      # @param name [Symbol] the fact name
      # @return [Boolean] true if `name`'s fact is `Absent`
      def absent?(name)  = fact(name).equal?(Absent)

      # A Present fact's value; nil for an explicit Null. Raises KeyError for
      # an Absent fact — "never offered" has no value, and answering nil
      # would re-conflate it with an explicit null, the very ambiguity this
      # type exists to remove. Ask `absent?`/`present?` first.
      #
      # @param name [Symbol] the fact name
      # @return [Object, nil] the offered value, or nil for an explicit Null
      # @raise [KeyError] if `name` was never offered
      def value(name)
        case (found = fact(name))
        when Present then found.value
        when Null then nil
        else raise KeyError, "#{verb} was not given #{name.inspect}"
        end
      end

      # The legacy args hash, byte for byte what `Routing.payload` returned
      # before this type existed: offered keys in offered order, Absent keys
      # omitted, Null keys mapped to nil. A fresh Hash every call.
      #
      # @return [Hash] the offered facts, Absent keys omitted and Null keys mapped to nil
      def to_args
        facts.each_with_object({}) do |(name, found), args|
          next if found.equal?(Absent)

          args[name] = found.equal?(Null) ? nil : found.value
        end
      end

      class << self
        # Builds the Invocation for one dispatch, reading the call's shape according to
        # `receiver:`.
        #
        # **One reading of a call's shape**. `receiver:` picks which of the
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
        # @param to [String, Hash, nil] the receiver: an aggregate identity, an entity route
        #   Hash with `:aggregate` and one of `:entity`/`:entities`, or nil
        # @param with [Hash, nil] the command's facts, keyed by argument name; may not be
        #   combined with a non-empty `legacy`
        # @param legacy [Hash] loose keyword facts, read when `with` is falsy
        # @param receiver [Symbol] which dispatch shape this is: `:aggregate`, `:entity`, or
        #   `:port`
        # @param entity_depth [Integer] the number of entity identities `to:` must carry, for
        #   `:entity`
        # @param aggregate [Bluebook::Aggregate, nil] the owning aggregate construct, read
        #   only for `:port`
        # @yield resolves the declaring command or port operation, once, at the point in the
        #   receiver's own order where it was always resolved
        # @yieldreturn [Bluebook::Command, Bluebook::PortOperation] the construct declaring
        #   the attributes facts are checked against
        # @return [Hecks::Runtime::Invocation] the built invocation
        # @raise [Runtime::TypeMismatch] if `to:` is malformed, `with:` is combined with loose
        #   keyword facts, or `with:` is not a Hash
        # @raise [Runtime::UnknownArgument] if `with:` offers a key the declaring construct
        #   does not declare
        # @raise [Runtime::AbsentArgument] if `with:` omits a non-optional declared attribute
        # @raise [ArgumentError] if `receiver` is none of `:aggregate`, `:entity`, `:port`
        def from_call(verb, to:, with:, legacy:, receiver: :aggregate, entity_depth: 0, aggregate: nil, &declaring)
          case receiver
          when :aggregate
            command = declaring.call
            facts   = facts_for(command, with: with, legacy: legacy)
            new(verb: verb, target: route(to), facts: facts)
          when :entity
            target  = route(to, entity_depth: entity_depth)
            command = declaring.call
            new(verb: verb, target: target, facts: facts_for(command, with: with, legacy: legacy))
          when :port
            port_call(verb, aggregate, declaring.call, to: to, with: with, legacy: legacy)
          else
            raise ArgumentError, "unknown receiver #{receiver.inspect}"
          end
        end

        # `to:` as a `Routing::Envelope`, or nil when no `to:` was given.
        #
        # @param to [String, Hash, nil] the receiver: an aggregate identity, an entity route
        #   Hash with `:aggregate` and one of `:entity`/`:entities`, or nil
        # @param entity_depth [Integer] the number of entity identities `to` must carry
        # @return [Routing::Envelope, nil] the parsed envelope, or nil when `to` is nil
        # @raise [Runtime::TypeMismatch] if `to` names no aggregate identity, carries the
        #   wrong number of entity identities, contains a blank identity, is neither a String
        #   nor a Hash, or names an unrecognized Hash key
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
        # @param declaring [Bluebook::Command, Bluebook::PortOperation] the construct whose
        #   `attributes` the facts are checked against
        # @param with [Hash, nil] the command's facts, keyed by argument name
        # @param legacy [Hash] loose keyword facts, read when `with` is falsy
        # @return [Hash{Symbol => Hecks::Runtime::Invocation::Present,
        #   Hecks::Runtime::Invocation::Null, Hecks::Runtime::Invocation::Absent}] each offered
        #   key mapped to `Null` (nil value) or `Present` (real value), in offered order, plus
        #   every declared attribute `with`/`legacy` did not offer, mapped to `Absent`
        # @raise [Runtime::TypeMismatch] if `with:` is combined with a non-empty `legacy`, or
        #   `with:` is not a Hash
        # @raise [Runtime::UnknownArgument] if `with:` offers a key `declaring` does not
        #   declare
        # @raise [Runtime::AbsentArgument] if `with:` omits a non-optional declared attribute
        def facts_for(declaring, with:, legacy:)
          offered = offered_facts(declaring, with: with, legacy: legacy)
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

        # **The port operation shape**.
        #
        # A Reference-typed attribute naming the owning aggregate is routing,
        # not a fact: lifted out of the loose kwargs into `to:` when no `to:`
        # was given. A `to:`-declared operation carries no Reference
        # attribute at all (PortOperationBuilder#initialize's own comment),
        # so its receiver is read — not removed — from the plain attribute
        # named for the owner's first `identified_by` field: that attribute
        # is still a declared external fact `refuse_absent_arguments`
        # expects to find (Rust's own comment: "declare only external facts
        # with attribute"; a real AbsentArgument confirmed this before `[]`
        # replaced `delete`). Composite identity is not attempted — `.first`
        # only, no domain in the corpus needs more for a port operation.
        def port_call(verb, aggregate, operation, to:, with:, legacy:)
          legacy = legacy.dup
          identity = operation.identity_attribute(aggregate.hecks_name)
          if to.nil? && identity && legacy.key?(identity.name)
            to = legacy.delete(identity.name)
          elsif to.nil? && operation.to == aggregate.hecks_name
            identity_name = Array(aggregate.identified_by).first
            to = legacy[identity_name] if identity_name && legacy.key?(identity_name)
          end

          target = route(to)
          raise TypeMismatch, "#{operation.hecks_name} requires its receiving aggregate in to:" unless target

          new(verb: verb, target: target, facts: facts_for(operation, with: with, legacy: legacy))
        end

        # BUG#7 — a non-Hash `to:` must be a String, matching Rust's
        # `RoutingEnvelope::from_json` (kernel/routing.rs), which refuses
        # anything neither a JSON string nor object before the domain payload
        # is examined. Surfaced on `examples/roster`'s `Mark`, whose own
        # attribute is literally named `to`: a flat-kwargs dispatch steals
        # that key into this parameter, and without this check an
        # out-of-range Integer would be accepted as the aggregate identity,
        # leaving Mark's `to` fact absent (AbsentArgument in Ruby,
        # TypeMismatch in Rust). See spec/runtime/routing_envelope_shape_spec.rb.
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
        # consulted: for an aggregate-level command (depth 0), without this
        # check `[].size == 0` would satisfy the depth check and let the
        # degenerate Hash reach the command's own validation. Rust's
        # `RoutingEnvelope::from_json` always refuses it at this point. A
        # bare aggregate identity String remains the ordinary
        # aggregate-command shape.
        def entity_identities(hash)
          raise TypeMismatch, "to: takes entity: or entities:, not both" if hash.key?(:entities) && hash.key?(:entity)

          identities = hash.key?(:entities) ? Array(hash[:entities]) : Array(hash[:entity])
          raise TypeMismatch, "to: entity route requires at least one entity identity" if identities.empty?

          identities
        end

        # `with:` is deliberately strict: a caller choosing the explicit
        # envelope cannot smuggle receiver identity back into the payload,
        # and may not mix it with loose keyword arguments. Without `with:`
        # (nil or false) the loose keyword arguments are the facts, unread —
        # whether `to:` was given never enters this decision (BUG#17).
        def offered_facts(declaring, with:, legacy:)
          if with && !legacy.empty?
            raise TypeMismatch,
                  "dispatch takes command facts in with:, not both with: and loose keyword arguments"
          end

          return legacy unless with
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
