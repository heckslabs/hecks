require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"
require_relative "../../rendering"
require_relative "../../ports/query/in_memory"

module Hecks
  module Runtime
    class CommandRules
      # A reference must point at something that exists.
      #
      # `reference_to Customer` is the one guarantee an aggregate reference is
      # for, and it was declared 14 times across banking and enforced nowhere :
      # an Account could belong to a customer who was never registered, and
      # every gate stayed green because
      # no corpus step ever passed a dangling reference.
      module References
        # Resolved here rather than in coercion because coercion is pure — it
        # holds no repository. A reference into another domain is left alone : a
        # cross-domain target may legitimately not be loaded, which is the same
        # reading `across` policies already get.
        #
        # Shared by CommandInterpreter and EntityInterpreter — an entity command
        # can declare a reference-typed attribute the same way an aggregate
        # command can, even though nothing in the real corpus does yet.
        #
        # @param domain [String] name of `command`'s domain
        # @param command [Bluebook::Command] the command whose reference-typed attributes are
        #   checked
        # @param args [Hash{Symbol => Object}] the command's normalized arguments
        # @return [void]
        # @raise [Runtime::NotFound] if an offered reference names a record its target
        #   aggregate's repository cannot find
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
        #
        # @param domain [String] name of `construct`'s domain
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the settled construct whose
        #   reference-typed attributes, and nested entities' own, are checked
        # @param state [Hash{Symbol => Object}] the settled state to validate; each nested
        #   entity's own list rows are recursed into
        # @return [void]
        # @raise [Runtime::TypeMismatch] if a required `has_one`/`belongs_to` relationship
        #   holds nil
        # @raise [Runtime::NotFound] if a held reference names a record its target
        #   aggregate's repository cannot find
        # @raise [Runtime::Unauthorized] if a held reference's target record disagrees with
        #   `state` about which tenant it belongs to
        def resolve_state_references(domain, construct, state)
          own_tenant_field = tenant_field_for(construct)

          construct.attributes.each do |attribute|
            next unless attribute.reference?

            held = state[attribute.name]
            validate_relationship_cardinality(construct, attribute, held)
            next if held.nil?

            target = referenced_aggregate(attribute)
            next unless target

            validate_reference_values(domain, target, held, list: attribute.list?)
            enforce_tenant_boundary(domain, construct, attribute, target, held, state, own_tenant_field)
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
        #
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct that declares
        #   `attribute`, named in the refusal
        # @param attribute [Bluebook::Attribute] the reference-typed attribute being checked;
        #   one with no `relationship`, or a list attribute, is never checked
        # @param held [Object, nil] the settled value of the field
        # @return [void]
        # @raise [Runtime::TypeMismatch] if `attribute` is a required (non-optional,
        #   non-list) relationship and `held` is nil
        def validate_relationship_cardinality(construct, attribute, held)
          return if attribute.relationship.nil? || attribute.list?
          return unless held.nil? && !attribute.optional?

          raise TypeMismatch,
                "#{construct.hecks_name}.#{attribute.name} is a required " \
                "#{attribute.relationship} relationship — expected one " \
                "#{attribute.type.target_name} identity, got nil"
        end

        # Resolves an attribute's `Reference<...>` type to the aggregate it names.
        #
        # The reference resolves itself — through the chapter's own IR, so the
        # bluebook's declared heads are the index.
        #
        # @param attribute [Bluebook::Attribute] a reference-typed attribute
        # @return [Bluebook::Aggregate, nil] the target aggregate; nil when the target
        #   belongs to another, unloaded domain
        def referenced_aggregate(attribute)
          attribute.type.resolve
        end

        # Refuses a held reference (or, for a list, any of its values) that names no record
        # in the target aggregate's own store.
        #
        # @param domain [String] name of the domain doing the checking, for resolving the
        #   target's repository
        # @param target [Bluebook::Aggregate] the aggregate `held` is supposed to reference
        # @param held [Object, Array] the offered or settled reference value(s); a bare
        #   scalar, or a compound identity's Hash/`Runtime::Value`
        # @param list [Boolean] true when `held` is a `has_many` relationship's own Array of
        #   values, false for a single reference
        # @return [void]
        # @raise [Runtime::NotFound] if any non-blank reference names no record the target
        #   aggregate's repository can find
        def validate_reference_values(domain, target, held, list:)
          values = list ? Array(held) : [held]
          values.each do |value|
            key = reference_key(value)
            next if key.empty?
            next if @registry.repository(domain, target).find(key)

            raise NotFound,
                  RefusalWording.render_site("NotFound", "reference_target_missing",
                                             target: target.name, heads: target.identity_heads.join(", "),
                                             key: key)
          end
        end

        # Angle-8's own write-side half of `TenantScope.apply` (runtime/
        # tenant_scope.rb) — the query-side mechanism this mirrors. That
        # module turns a declared `authorize policy, tenant: :field` into a
        # synthetic where-clause checked against the caller's own supplied
        # tenant argument; there is no caller-identity/session system this
        # runtime has to check a write's caller against (TenantScope's own
        # header names that as a separate, still-open gap), so this checks
        # the one thing that is available without one: whether the record
        # being written and the record it references agree about which
        # tenant they belong to. `lib/hecks/fuzzing/properties/guards.rb`'s
        # `commands_respect_tenant_scope` states the identical claim,
        # read off `history[:instances]` after the fact — this is what
        # makes that claim hold by construction (a refused write is never
        # stored) rather than merely checked for regression.
        #
        # Hooked into `resolve_state_references` rather than a new
        # DISPATCH_ORDER step deliberately: that method already walks
        # every `reference_to`-typed attribute against the settled,
        # post-mutation state (the same moment `commands_respect_tenant_
        # scope` itself inspects), already resolves the referenced record
        # through the repository right above, and already runs from both
        # `CommandInterpreter#step_save` and `EntityInterpreter#step_save`
        # — one change, both interpreters covered, no new vocabulary step
        # to keep in sync with `Vocabulary::AggregateDispatchOrder`/
        # `EntityDispatchOrder`.
        #
        # @param domain [String] name of the domain doing the checking
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct that owns
        #   `attribute` and `own_tenant_field`
        # @param attribute [Bluebook::Attribute] the reference-typed attribute pointing at
        #   `target`
        # @param target [Bluebook::Aggregate] the aggregate `held` references
        # @param held [Object, Array] the settled reference value(s)
        # @param state [Hash{Symbol => Object}] the settled state `own_tenant_field` is read from
        # @param own_tenant_field [Symbol, nil] `construct`'s own tenant-scoping field, from
        #   `tenant_field_for`; nil skips the check entirely
        # @return [void]
        # @raise [Runtime::Unauthorized] if a referenced record declares a different tenant
        #   value on its own matching field
        def enforce_tenant_boundary(domain, construct, attribute, target, held, state, own_tenant_field)
          return unless own_tenant_field && state.key?(own_tenant_field)

          target_tenant_field = tenant_field_for(target)
          return unless target_tenant_field

          own_tenant = Ports::Query::InMemory.comparable(state[own_tenant_field])

          values = attribute.list? ? Array(held) : [held]
          values.each do |value|
            key = reference_key(value)
            next if key.empty?

            record = @registry.repository(domain, target).find(key)
            next unless record&.state&.key?(target_tenant_field)

            target_tenant = Ports::Query::InMemory.comparable(record.state[target_tenant_field])
            next if target_tenant == own_tenant

            raise Unauthorized,
                  RefusalWording.render_site("Unauthorized", "cross_tenant_reference",
                                             aggregate: construct.hecks_name, field: own_tenant_field,
                                             tenant: Rendering.describe(state[own_tenant_field]),
                                             attribute: attribute.name, target: target.name,
                                             target_field: target_tenant_field,
                                             other: Rendering.describe(record.state[target_tenant_field]))
          end
        end

        # The field an aggregate's own query names as tenant-scoping — the
        # exact same lookup `Fuzzing::Properties::Guards#tenant_field_for`
        # already established for the property that found this gap, reused
        # here rather than reinvented: an aggregate's own declared tenant
        # field is whichever field one of its own queries names in
        # `authorize policy, tenant: :field`. `nil` for a construct that
        # declares no such query — not every aggregate is tenant-scoped,
        # and an entity never declares a query of its own at all today
        # (`Entity.queries` is always empty in the real corpus), so this
        # answers `nil` for every entity without needing to special-case
        # one.
        #
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct to read a
        #   tenant field off
        # @return [Symbol, nil] the field named by the construct's own `authorize policy,
        #   tenant: :field`; nil when it declares no such query
        def tenant_field_for(construct)
          authorization = construct.queries.filter_map(&:authorization).find(&:tenant)
          authorization&.tenant&.to_sym
        end

        # `value` is the referenced record's own id, exactly as `Identity.of`
        # would build it for that record — a bare scalar for a single-field
        # identity (the overwhelming common case; Banking's own plain
        # `reference_to Customer` holds one already, so `Value.
        # materialize_unwrapped` is a no-op passthrough here), or a
        # `Naming.identity`-joined string for a compound one
        # (`belongs_to Translation, as: :translation_ref` — Translation's
        # own `identified_by :domain, :from, :to`, three fields). Before
        # this, plain `value.to_s` on that compound case's own coerced
        # Value hit Ruby's default `Object#to_s` (a raw, run-to-run-random
        # memory address) instead of joining the record's real id — found
        # live via bin/fuzz on the self-hosted "translation" domain
        # (replay_is_deterministic), the same class of gap `Identity.from`
        # already had for a compound `identified_by`'s own bare (undotted)
        # attribute paths. `materialize_unwrapped` recurses a multi-
        # attribute value object to a plain Hash keyed by attribute name,
        # in declaration order — `Naming.identity` on `.values` reproduces
        # the identical join `Identity.of` itself would produce for the
        # same fields.
        #
        # @param value [Object, nil] a held reference: a bare scalar, a `Runtime::Value`, or
        #   a Hash
        # @return [String] the target record's id, ready for a repository `find`; `""` for
        #   nil or any value that unwraps to no fields
        def reference_key(value)
          unwrapped = Value.materialize_unwrapped(value)
          return Naming.identity(unwrapped.values).to_s if unwrapped.is_a?(Hash)

          unwrapped.to_s
        end

        # A command argument's own related record, reachable by name from
        # `given`/`ensures` — `disputed_by.status`, say, `CardPayment
        # .Dispute`'s own fresh `Reference<Customer>` argument — without
        # teaching the pure expression evaluator anything about
        # repositories. The lookup happens here, once, before evaluation;
        # `Resolver#lookup` just digs into a plain Hash exactly as it
        # always has.
        #
        # `owner` narrowed to `command` only (S12, ADR 0025 — "rules
        # confined to their own aggregate boundary"): this method never
        # dereferences the declaring aggregate/entity's own stored
        # `reference_to` — a live query against another aggregate's own
        # repository on every `given`/`ensures`/`invariant` run. A
        # cross-aggregate fact a rule needs has to be a
        # `projects`-maintained local field (`AggregateBuilder#projects_impl`'s
        # own comment), already present in `subject`'s own state, no hydration needed. A
        # reference-typed command argument stays in bounds, though — the
        # ADR's own boundary list names "its command arguments" as
        # readable, and nothing is stored yet for a fresh argument to
        # project from; resolving it once here, synchronous with this
        # command's own admission, is a different shape from a live query
        # against an already-persisted reference. `enforce_givens`/
        # `enforce_ensures` are this method's only two remaining callers,
        # both passing `command`/`args`, never a `subject`'s own
        # aggregate — verified before this comment was written, not
        # assumed.
        #
        # Recurses into what it finds, so a chain deeper than one hop
        # still resolves in one pass. Depth-bounded rather than cycle-
        # detected — nothing in this corpus dots more than two hops on a
        # fresh argument, and a bound is simpler than tracking visited
        # (type, id) pairs for a cycle nothing here declares.
        DEREFERENCE_DEPTH = 4
        private_constant :DEREFERENCE_DEPTH

        # Hydrates a command's fresh reference-typed arguments to the records they name, so
        # `given`/`ensures` can read them by name (`disputed_by.status`).
        #
        # @param domain [String] name of `owner`'s domain
        # @param owner [Bluebook::Command, nil] the construct whose reference-typed attributes
        #   are hydrated; nil (or a depth of 0) hydrates nothing
        # @param source [Hash{Symbol => Object}] the arguments to read each reference's id from
        # @param depth [Integer] how many further hops to recurse; defaults to
        #   `DEREFERENCE_DEPTH`
        # @return [Hash{Symbol => Hash}] one entry per reference-typed attribute that resolved
        #   to a real record, keyed by the attribute's name with a trailing `_id` stripped;
        #   each value is that record's state, merged with its own references dereferenced
        #   one level further in
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
