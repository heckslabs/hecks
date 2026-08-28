require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecks
  module Runtime
    class CommandRules
      # A reference must point at something that EXISTS.
      #
      # `reference_to Customer` is the one guarantee an aggregate reference is
      # for, and it was declared 14 times across banking and enforced nowhere :
      # an Account could belong to a customer who was never registered, and
      # every gate stayed green because
      # no corpus step ever passed a dangling reference.
      module References
        # Resolved here rather than in coercion because coercion is pure — it
        # holds no repository. A reference INTO ANOTHER DOMAIN is left alone : a
        # cross-domain target may legitimately not be loaded, which is the same
        # reading `across` policies already get.
        #
        # Shared by CommandInterpreter and EntityInterpreter — an entity command
        # can declare a reference-typed attribute the same way an aggregate
        # command can, even though nothing in the real corpus does yet.
        def resolve_references(domain, command, args)
          command.attributes.each do |attribute|
            next unless attribute.reference?
            next unless args.key?(attribute.name)

            held = args[attribute.name]
            next if held.nil?

            target = referenced_aggregate(attribute)
            next unless target

            validate_reference_values(domain, target, held, list: attribute.list?)
          end
        end

        # Structural references are checked again against the settled state.
        # This is what makes a `has_many` declared on an aggregate honest even
        # when a command supplies its list through an ordinary typed argument.
        def resolve_state_references(domain, construct, state)
          construct.attributes.each do |attribute|
            next unless attribute.reference?

            held = state[attribute.name]
            validate_relationship_cardinality(construct, attribute, held)
            next if held.nil?

            target = referenced_aggregate(attribute)
            next unless target

            validate_reference_values(domain, target, held, list: attribute.list?)
          end

          Array(construct.entities).each do |entity|
            field = construct.attribute(Naming.snake(entity.hecks_name).to_sym) ||
                    construct.attributes.find { |attribute| attribute.type.to_s == entity.hecks_name.to_s }
            next unless field

            Array(state[field.name]).each { |row| resolve_state_references(domain, entity, row) }
          end
        end

        # `has_one` and `belongs_to` mean exactly one target unless the
        # declaration explicitly says optional. State validation owns this
        # boundary because a command may leave an aggregate field untouched;
        # checking only command arguments would let a required relationship be
        # persisted as nil. `has_many` admits zero members, so its empty list is
        # already a valid cardinality and needs no presence refusal.
        def validate_relationship_cardinality(construct, attribute, held)
          return if attribute.relationship.nil? || attribute.list?
          return unless held.nil? && !attribute.optional?

          raise TypeMismatch,
                "#{construct.hecks_name}.#{attribute.name} is a required " \
                "#{attribute.relationship} relationship — expected one " \
                "#{attribute.type.target_name} identity, got nil"
        end

        # The reference RESOLVES itself — through the chapter's own IR, so the
        # bluebook's declared heads are the index. This used to regex the target's
        # name out of "Reference<Customer>" and then search
        # `registry.bluebook(domain).aggregates` for it — and later reached the
        # target through Ruby's constant tree, a class thrown away for its `.ir`
        # the moment it was found.
        def referenced_aggregate(attribute)
          attribute.type.resolve
        end

        def validate_reference_values(domain, target, held, list:)
          values = list ? Array(held) : [held]
          values.each do |value|
            key = reference_key(value)
            next if key.empty?
            next if @registry.repository(domain, target).find(key)

            raise NotFound,
                  RefusalWording.render("NotFound", "reference_target_missing",
                                        target: target.name, heads: target.identity_heads.join(", "),
                                        key: key.inspect)
          end
        end

        # `value` is the referenced record's own id, EXACTLY as `Identity.of`
        # would build it for that record — a bare scalar for a single-field
        # identity (the overwhelming common case; Banking's own plain
        # `reference_to Customer` holds one already, so `Value.
        # materialize_unwrapped` is a no-op passthrough here), or a
        # `Naming.identity`-joined string for a compound one
        # (`belongs_to Translation, as: :translation_ref` — Translation's
        # own `identified_by :domain, :from, :to`, THREE fields). Before
        # this, plain `value.to_s` on that compound case's own coerced
        # Value hit Ruby's default `Object#to_s` (a raw, run-to-run-random
        # memory address) instead of joining the record's real id — found
        # live via bin/fuzz on the self-hosted "translation" domain
        # (replay_is_deterministic), the SAME class of gap `Identity.from`
        # already had for a compound `identified_by`'s own bare (undotted)
        # attribute paths. `materialize_unwrapped` recurses a multi-
        # attribute value object to a plain Hash keyed by attribute name,
        # in declaration order — `Naming.identity` on `.values` reproduces
        # the identical join `Identity.of` itself would produce for the
        # SAME fields.
        def reference_key(value)
          unwrapped = Value.materialize_unwrapped(value)
          return Naming.identity(unwrapped.values).to_s if unwrapped.is_a?(Hash)

          unwrapped.to_s
        end

        # A COMMAND ARGUMENT's own related record, reachable by name from
        # `given`/`ensures` — `disputed_by.status`, say, `CardPayment
        # .Dispute`'s own fresh `Reference<Customer>` argument — without
        # teaching the pure expression evaluator anything about
        # repositories. The lookup happens HERE, once, before evaluation;
        # `Resolver#lookup` just digs into a plain Hash exactly as it
        # always has.
        #
        # `owner` NARROWED TO `command` ONLY (S12, ADR 0025 — "rules
        # confined to their own aggregate boundary"): dereferencing the
        # DECLARING aggregate/entity's own STORED `reference_to` used to
        # be the other half of this method's job — a live query against
        # another aggregate's own repository, every time a `given`/
        # `ensures`/`invariant` ran. That half is gone; a cross-aggregate
        # fact a rule needs now has to be a `projects`-maintained LOCAL
        # field (`AggregateBuilder#projects_impl`'s own comment), already
        # present in `subject`'s own state, no hydration needed. A
        # reference-typed COMMAND ARGUMENT stays in bounds, though — the
        # ADR's own boundary list names "its command arguments" as
        # readable, and nothing is stored yet for a fresh argument to
        # project from; resolving it once here, synchronous with THIS
        # command's own admission, is a different shape from a live query
        # against an ALREADY-PERSISTED reference. `enforce_givens`/
        # `enforce_ensures` are this method's only two remaining callers,
        # both passing `command`/`args`, never a `subject`'s own
        # aggregate — verified before this comment was written, not
        # assumed.
        #
        # RECURSES into what it finds, so a chain deeper than one hop
        # still resolves in one pass. Depth-bounded rather than cycle-
        # detected — nothing in this corpus dots more than two hops on a
        # fresh argument, and a bound is simpler than tracking visited
        # (type, id) pairs for a cycle nothing here declares.
        DEREFERENCE_DEPTH = 4
        private_constant :DEREFERENCE_DEPTH

        def dereference(domain, owner, source, depth: DEREFERENCE_DEPTH)
          return {} if depth <= 0 || owner.nil?

          owner.attributes.each_with_object({}) do |attribute, hydrated|
            next unless attribute.reference?

            id = source[attribute.name]
            next if id.nil?

            target = referenced_aggregate(attribute)
            next unless target

            record = @registry.repository(domain, target).find(id.to_s)
            next unless record

            name = attribute.name.to_s.sub(/_id\z/, "").to_sym
            hydrated[name] = record.state.merge(dereference(domain, target, record.state, depth: depth - 1))
          end
        end
      end
    end
  end
end
