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
        # @param domain [String, Symbol] the domain the referenced aggregate is
        #   resolved in
        # @param command [Class] the command or port-operation class (`Bluebook::Command`
        #   or `PortOperation` subclass) whose reference-typed attributes are checked
        # @param args [Hash{Symbol => Object}] the offered, already-coerced argument values
        # @return [void]
        # @raise [Runtime::NotFound] if a reference-typed argument names an identity that
        #   does not exist in its target aggregate's repository
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
        # @param domain [String, Symbol] the domain the referenced aggregate is
        #   resolved in
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct
        #   whose reference-typed attributes are checked against `state`
        # @param state [Hash{Symbol => Object}] the settled, post-mutation state to
        #   check every reference and relationship cardinality against
        # @return [void]
        # @raise [Runtime::TypeMismatch] if a required `has_one`/`belongs_to`
        #   relationship holds nil
        # @raise [Runtime::NotFound] if a reference-typed field names an identity
        #   that does not exist in its target aggregate's repository
        # @raise [Runtime::Unauthorized] if a referenced record belongs to a
        #   different tenant than `construct`'s own record
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
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct
        #   `attribute` is declared on, named in a refusal
        # @param attribute [Bluebook::Attribute] the reference-typed attribute to check
        # @param held [Object, nil] the field's settled value
        # @return [void]
        # @raise [Runtime::TypeMismatch] if `attribute` declares a required (non-optional,
        #   non-list) `has_one`/`belongs_to` relationship and `held` is nil
        def validate_relationship_cardinality(construct, attribute, held)
          return if attribute.relationship.nil? || attribute.list?
          return unless held.nil? && !attribute.optional?

          raise TypeMismatch,
                "#{construct.hecks_name}.#{attribute.name} is a required " \
                "#{attribute.relationship} relationship — expected one " \
                "#{attribute.type.target_name} identity, got nil"
        end

        # The reference resolves itself — through the chapter's own IR, so the
        # bluebook's declared heads are the index, rather than regexing the
        # target's name out of "Reference<Customer>" and searching
        # `registry.bluebook(domain).aggregates` for it, or reaching the
        # target through Ruby's constant tree, a class thrown away for its
        # `.ir` the moment it was found.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute to resolve
        # @return [Bluebook::Aggregate, nil] the target aggregate the reference names,
        #   or nil if it cannot be resolved
        # @raise [Bluebook::DSL::Malformed] if the reference does not know which
        #   aggregate declares it
        def referenced_aggregate(attribute)
          attribute.type.resolve
        end

        # Refuses a reference-typed value whose target identity does not exist.
        #
        # @param domain [String, Symbol] the domain `target` is resolved in
        # @param target [Bluebook::Aggregate] the referenced aggregate
        # @param held [Object, Array<Object>] the offered value: a single reference,
        #   or, when `list:` is true, an Array of them
        # @param list [Boolean] whether `held` is list-shaped
        # @return [void]
        # @raise [Runtime::NotFound] if any referenced identity does not exist in
        #   `target`'s repository
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
        # @param domain [String, Symbol] the domain `target` is resolved in
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct
        #   `attribute` is declared on, named in a refusal
        # @param attribute [Bluebook::Attribute] the reference-typed attribute being
        #   checked
        # @param target [Bluebook::Aggregate] the referenced aggregate
        # @param held [Object, Array<Object>] the offered value: a single reference,
        #   or, when `attribute.list?` is true, an Array of them
        # @param state [Hash{Symbol => Object}] `construct`'s own settled state, read
        #   for its own tenant field's value
        # @param own_tenant_field [Symbol, nil] `construct`'s own declared tenant field;
        #   a no-op if nil or absent from `state`
        # @return [void]
        # @raise [Runtime::Unauthorized] if a referenced record's own tenant field
        #   disagrees with `construct`'s
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
        # @param construct [Bluebook::Aggregate, Bluebook::Entity] the construct
        #   whose declared queries are searched
        # @return [Symbol, nil] the tenant-scoping field name, or nil if `construct`
        #   declares no query with `authorize policy, tenant: :field`
        def tenant_field_for(construct)
          authorization = construct.queries.filter_map(&:authorization).find(&:tenant)
          authorization&.tenant&.to_sym
        end

        # Renders a reference-typed value as the plain string key its target
        # record is looked up by.
        #
        # `value` is the referenced record's own id, exactly as `Identity.of`
        # would build it for that record — a bare scalar for a single-field
        # identity (the overwhelming common case; Banking's own plain
        # `reference_to Customer` holds one already, so `Value.
        # materialize_unwrapped` is a no-op passthrough here), or a
        # `Naming.identity`-joined string for a compound one
        # (`belongs_to Translation, as: :translation_ref` — Translation's
        # own `identified_by :domain, :from, :to`, three fields). Without
        # `materialize_unwrapped`, plain `value.to_s` on that compound case's
        # own coerced Value would hit Ruby's default `Object#to_s` (a raw,
        # run-to-run-random memory address) instead of joining the record's
        # real id — found live via bin/fuzz on the self-hosted "translation"
        # domain (replay_is_deterministic), the same class of gap `Identity.from`
        # already had for a compound `identified_by`'s own bare (undotted)
        # attribute paths. `materialize_unwrapped` recurses a multi-
        # attribute value object to a plain Hash keyed by attribute name,
        # in declaration order — `Naming.identity` on `.values` reproduces
        # the identical join `Identity.of` itself would produce for the
        # same fields.
        #
        # @param value [Object] the offered reference value: a `Runtime::Value`, a
        #   scalar, or anything `Value.materialize_unwrapped` can open
        # @return [String] the key to look the referenced record up by; empty when
        #   `value` names no id
        def reference_key(value)
          unwrapped = Value.materialize_unwrapped(value)
          return Naming.identity(unwrapped.values).to_s if unwrapped.is_a?(Hash)

          unwrapped.to_s
        end

        # Hydrates a command argument's own related record, reachable by name
        # from `given`/`ensures` — `disputed_by.status`, say, `CardPayment
        # .Dispute`'s own fresh `Reference<Customer>` argument — without
        # teaching the pure expression evaluator anything about
        # repositories. The lookup happens here, once, before evaluation;
        # `Resolver#lookup` just digs into a plain Hash exactly as it
        # always has.
        #
        # `owner` narrowed to `command` only (S12, ADR 0025 — "rules
        # confined to their own aggregate boundary"): dereferencing the
        # declaring aggregate/entity's own stored `reference_to` is not part
        # of this method's job — a cross-aggregate fact a rule needs has to
        # be a `projects`-maintained local field (`AggregateBuilder#
        # projects_impl`'s own comment), already present in `subject`'s own
        # state, no hydration needed, rather than a live query against
        # another aggregate's own repository on every `given`/`ensures`/
        # `invariant` run. A reference-typed command argument stays in
        # bounds, though — the ADR's own boundary list names "its command
        # arguments" as readable, and nothing is stored yet for a fresh
        # argument to project from; resolving it once here, synchronous
        # with this command's own admission, is a different shape from a
        # live query against an already-persisted reference. `enforce_givens`/
        # `enforce_ensures` are this method's only two remaining callers,
        # both passing `command`/`args`, never a `subject`'s own
        # aggregate — verified by grep, not assumed.
        #
        # Recurses into what it finds, so a chain deeper than one hop
        # still resolves in one pass. Depth-bounded rather than cycle-
        # detected — nothing in this corpus dots more than two hops on a
        # fresh argument, and a bound is simpler than tracking visited
        # (type, id) pairs for a cycle nothing here declares.
        DEREFERENCE_DEPTH = 4
        private_constant :DEREFERENCE_DEPTH

        # Hydrates `owner`'s own reference-typed attributes into the records they name.
        #
        # @param domain [String, Symbol] the domain a referenced aggregate is
        #   resolved in
        # @param owner [Class, Bluebook::Aggregate, Bluebook::Entity, nil] the
        #   construct whose reference-typed attributes are dereferenced; nil (or a
        #   depth of zero) short-circuits to an empty Hash
        # @param source [Hash{Symbol => Object}] the offered payload to read each
        #   reference-typed attribute's raw id from
        # @param depth [Integer] how many more hops to recurse into a resolved
        #   reference's own reference-typed fields
        # @return [Hash{Symbol => Object}] one entry per resolved reference-typed
        #   attribute, keyed by the attribute name with a trailing `_id` stripped,
        #   valued at the referenced record's state merged with its own dereferenced
        #   references; an attribute with no id, an unresolvable target, or no
        #   matching record contributes nothing
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
