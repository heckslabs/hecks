require_relative "errors"
require_relative "refusal_wording"
require_relative "../rendering"

module Hecks
  module Runtime
    # The invocation address is not part of a command's domain payload.
    # Aggregate commands carry one receiver identity; entity commands carry
    # the aggregate receiver followed by one identity for every entity hop.
    module Routing
      Envelope = Struct.new(:aggregate, :entities, keyword_init: true) do
        def initialize(aggregate:, entities: [])
          super(aggregate: aggregate.to_s, entities: Array(entities).map(&:to_s).freeze)
          freeze
        end
      end

      module_function

      def envelope(to, entity_depth: 0)
        return nil if to.nil?

        aggregate, entities = to.is_a?(Hash) ? parse_envelope_hash(to) : scalar_envelope(to)

        raise TypeMismatch, "to: must name the receiving aggregate identity" if aggregate.nil? || aggregate.to_s.empty?
        if entities.size != entity_depth
          raise TypeMismatch,
                "to: for an entity command needs #{entity_depth} entity " \
                "#{entity_depth == 1 ? 'identity' : 'identities'} after the aggregate — got #{entities.size}"
        end
        raise TypeMismatch, "to: contains a blank entity identity" if entities.any? do |identity|
          identity.nil? || identity.to_s.empty?
        end

        Envelope.new(aggregate: aggregate, entities: entities)
      end

      # BUG#7 — the non-Hash half of `to:` used to accept ANY Ruby object
      # (`[to, []]`, unconditionally) as though it were a ready-made
      # aggregate identity scalar. That is looser than the JSON step
      # boundary (`bin/run`/`Fuzzing::Replay`/`StepBuilder`) ever needs it
      # to be — every legitimate caller already hands this a `String`
      # (`Naming.identity` canonicalizes every identity to one before it
      # ever reaches a `to:`/legacy-args door) — and looser than Rust's own
      # hand-written mirror of this exact boundary
      # (`rust/src/kernel/routing.rs#RoutingEnvelope::from_json`, its own
      # header: "Generated routers accept this shape while retaining the
      # legacy mixed-args object as a compatibility input during
      # migration"), which refuses anything that is neither a JSON string
      # nor object outright, TypeMismatch, before ever reaching a domain's
      # own command payload.
      #
      # The gap surfaced live on `examples/roster` — the first domain in
      # this corpus to declare a command attribute literally named `to`
      # (`Roster::Roster.Mark`, deliberately, per that bluebook's own
      # header comment). `bin/qa_sweep`'s legacy-args dispatch convention
      # (`runtime.dispatch(verb, **symbolize(args))`, `step_builder.rb`)
      # flattens a command's own declared fact and its routing target into
      # ONE Ruby kwargs hash — completely ordinary for every other domain,
      # since Ruby's keyword-argument binding only steals a key that
      # collides with `dispatch`'s own `to:`/`with:`/`saga_correlation:`
      # parameter names. `Mark`'s `to` does collide, so a fuzzer-corrupted
      # scalar offered for it (an out-of-range Integer, from
      # `InvalidValueGenerator.corrupt`) was routed here as the AGGREGATE
      # IDENTITY instead of the domain's own required argument — accepted
      # unconditionally, leaving `Mark`'s own `to` fact absent from the
      # payload entirely. Ruby refused `AbsentArgument` ("Mark was not
      # given to — it takes to"); Rust's stricter `RoutingEnvelope::
      # from_json` refuses the malformed scalar itself, TypeMismatch,
      # before the domain payload is ever examined — the observed
      # divergence. Tightening this branch to Rust's own contract (a
      # scalar `to:` must be a `String`) makes both refuse the same way,
      # for the same reason, at the same step.
      def scalar_envelope(to)
        return [to, []] if to.is_a?(String)

        raise TypeMismatch, "to: must be a string aggregate identity or an entity route, got #{Rendering.describe(to)}"
      end
      private_class_method :scalar_envelope

      # The Hash-shaped half of `to:` — pulled out of `envelope` because
      # it is a self-contained parse (raises on an unrecognized key, then
      # returns the pair) with no dependency on anything `envelope` does
      # afterward; the validations that follow apply the same way
      # whichever branch produced `aggregate`/`entities`.
      def parse_envelope_hash(to)
        hash = to.transform_keys(&:to_sym)
        unknown = hash.keys - %i[aggregate entity entities]
        raise TypeMismatch, "to: does not recognize #{unknown.sort.join(', ')}" unless unknown.empty?

        [hash[:aggregate], entity_identities(hash)]
      end
      private_class_method :parse_envelope_hash

      # `with:` is deliberately strict. Compatibility-only calls still pass
      # loose keyword arguments through the old addressing gate, but a caller
      # choosing the explicit envelope cannot smuggle receiver identity back
      # into the payload.
      def payload(command, with:, legacy:)
        if with && !legacy.empty?
          raise TypeMismatch,
                "dispatch takes command facts in with:, not both with: and loose keyword arguments"
        end

        return legacy unless with
        raise TypeMismatch, "with: must be a hash of command facts" unless with.is_a?(Hash)

        offered = with.transform_keys(&:to_sym)
        declared = command.attributes.map { |attribute| attribute.name.to_sym }
        refuse_unknown_facts!(command, offered, declared)
        refuse_absent_facts!(command, offered, declared)
        offered
      end

      # The two `with:` shape checks `payload` runs in sequence — pulled
      # out because each is a self-contained "compute a difference, raise
      # if non-empty" rule with no dependency on the other. Order stays
      # unknown-before-absent, exactly as inline: `payload` calls them in
      # that order, so a fact that is both unknown AND leaves something
      # else absent still raises UnknownArgument first, same as before.
      def refuse_unknown_facts!(command, offered, declared)
        unknown = (offered.keys - declared).sort
        return if unknown.empty?

        reading = declared.empty? ? "none" : declared.join(", ")
        raise UnknownArgument,
              RefusalWording.render("UnknownArgument", "unknown_args",
                                    command: command.hecks_name, unknown: unknown.join(", "),
                                    declared: reading)
      end
      private_class_method :refuse_unknown_facts!

      def refuse_absent_facts!(command, offered, declared)
        absent = command.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym } - offered.keys
        return if absent.empty?

        reading = declared.empty? ? "none" : declared.join(", ")
        raise AbsentArgument,
              RefusalWording.render("AbsentArgument", "absent_args",
                                    command: command.hecks_name, absent: absent.sort.join(", "),
                                    declared: reading)
      end
      private_class_method :refuse_absent_facts!

      def entity_identities(hash)
        raise TypeMismatch, "to: takes entity: or entities:, not both" if hash.key?(:entities) && hash.key?(:entity)

        hash.key?(:entities) ? Array(hash[:entities]) : Array(hash[:entity])
      end
      private_class_method :entity_identities
    end
  end
end
