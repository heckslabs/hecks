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

        # A related record's OWN fields, reachable by name from `given`/
        # `ensures` — `customer.status`, `account.customer.status` — without
        # teaching the pure expression evaluator anything about
        # repositories. The lookup happens HERE, once, before evaluation;
        # `Resolver#lookup` just digs into a plain Hash exactly as it
        # always has.
        #
        # `owner` is either the declaring aggregate/entity (its OWN
        # `reference_to`, read off `source` — the record's stored state)
        # or the command itself (a reference-typed ARGUMENT, read off
        # `source` — the dispatch payload). Same shape either way: every
        # reference-typed attribute `owner` declares becomes a key in the
        # result, named by stripping the attribute's own `_id` suffix
        # (`customer_id` → `customer`) — a no-op for an aliased reference
        # that already carries no suffix (`reference_to Account, as:
        # :source` → `source`), which is why this needs no separate case
        # for `as:`.
        #
        # RECURSES into what it finds, so a chain like
        # `account.customer.status` resolves in one pass: hydrating
        # `account` also hydrates ITS OWN `customer_id` into a nested
        # `customer` key. Depth-bounded rather than cycle-detected — nothing
        # in this corpus dots more than two hops, and a bound is simpler
        # than tracking visited (type, id) pairs for a cycle nothing here
        # declares.
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
