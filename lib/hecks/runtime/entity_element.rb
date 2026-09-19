require_relative "../naming"
require_relative "../freezer"
require_relative "value"
require_relative "refusal_wording"
require_relative "errors"
require_relative "identity"
require_relative "instance"

module Hecks
  module Runtime
    # **One entity element, located and mutated** — the walk-and-write half of
    # dispatching into a piece an aggregate holds, factored out of
    # `EntityInterpreter` so a second caller (`CommandInterpreter`'s own
    # `delegate_to_entity` step) can locate and mutate the same element the
    # same way, against an aggregate record it already holds in memory
    # rather than one freshly loaded from a repository. `EntityInterpreter`
    # keeps its own dispatch order and Context; this is the part underneath
    # that both now share, so it exists in exactly one place rather than two
    # that could only ever drift (the same reasoning `Runtime::Identity`'s
    # own header gives for the join/dig/reading trio it centralizes).
    #
    # `rules` (a `CommandRules` instance) is passed explicitly throughout
    # rather than closed over, since this module has no instance of its own
    # to hold one.
    module EntityElement
      module_function

      # BUG#3 — an addressing value that can never match a stored element,
      # returned from `element_of`'s own `wants` coercion in place of a real
      # `Value` (below). A unique object, never `nil`: a stored, optional
      # element field really can hold `nil`, and comparing that against a
      # bare `nil` sentinel would accidentally "match" it.
      UNMATCHABLE = Object.new.freeze
      private_constant :UNMATCHABLE

      # Walks `chain`, one hop per entry, and returns the located element (or
      # `instance` itself, when `chain` is empty).
      #
      # **One hop per chain entry**. `container` starts as `instance` (the root
      # aggregate record) and becomes each just-located element in turn —
      # Dispatch's own element is found inside the Handler element
      # `locate_chain` located the step before, never inside `instance`
      # directly. `owner` is whichever construct's own attribute declares
      # the list being searched (Handler declares `dispatches` ; the root
      # aggregate declares `handlers`) — `root_aggregate` stays the root
      # the whole way through instead, passed to `element_of` separately,
      # because coercion (`Value.for_attribute`) resolves value objects
      # against the root's own namespace only ; an entity must never
      # answer `.value_object` (Entity's own header comment) so handing
      # it an intermediate owner instead would break every VO-typed
      # identity field a nested entity declares.
      #
      # `route`, if given, is the routing envelope's own entity chain
      # (`ctx.route.entities`, one entry per hop) — the routing/payload
      # split's own consequence: an entity's own identity may arrive via
      # `to:` rather than duplicated into `args`, so each hop is offered
      # its routed identity ahead of falling back to `args`.
      #
      # @param root_aggregate [Bluebook::Aggregate] the root aggregate record's
      #   own construct, held constant across every hop for coercion
      # @param chain [Array<Bluebook::Entity>] the entity chain to walk, root-first
      # @param instance [Runtime::Instance] the root aggregate record to walk from
      # @param args [Hash{String, Symbol => Object}] the offered command arguments,
      #   read for each hop's own identity when `route` does not supply it
      # @param command_name [String] the command name, quoted in a refusal
      # @param route [Runtime::Routing::Envelope, nil] the call's resolved routing
      #   envelope, if any; its own `entities` supply each hop's identity first
      # @return [Runtime::Instance, Hash{Symbol => Object}] the located element;
      #   `instance` itself, unchanged, when `chain` is empty
      # @raise [Runtime::UnknownVerb] if a hop's owner declares no list attribute
      #   for that entity
      # @raise [Runtime::NotFound] if a hop's identity is absent from `args`, or no
      #   element matches it
      def locate_chain(root_aggregate, chain, instance, args, command_name, route = nil)
        container = instance
        owner     = root_aggregate
        chain.each_with_index do |entity, index|
          container = element_of(root_aggregate, owner, entity, command_name, container, args,
                                 route&.entities&.fetch(index))
          owner = entity
        end
        container
      end

      # One element, matched on every part of its identity — not just the first.
      # A piece's identity may be several paths, the same shape a head's can be,
      # so a dispatch that names the element has to supply every part and every
      # part has to agree with the stored one. `routed_identity`, when given,
      # matches by the element's own minted identity string directly instead
      # (`element_identity`, below) — the routing envelope already resolved
      # which element it means, so re-deriving `wants` from `args` would be
      # redundant at best and wrong if `args` no longer carries that identity
      # at all.
      # Locate, then copy-before-mutate, in that order — see the "one
      # level deeper" comment below on why the copy has to happen exactly
      # where it does (aliasing the adapter's own record otherwise).
      # Splitting resolution from the copy/write-back would separate two
      # halves of one aliasing-safety invariant across method boundaries.
      # rubocop:disable-next Metrics/AbcSize
      # rubocop:disable-next Metrics/CyclomaticComplexity
      # rubocop:disable-next Metrics/PerceivedComplexity
      # rubocop:disable-next Metrics/MethodLength
      #
      # @param root_aggregate [Bluebook::Aggregate] the root aggregate record's own
      #   construct, used for value-object coercion
      # @param owner [Bluebook::Aggregate, Bluebook::Entity] the construct whose own
      #   attribute declares the list `entity` is searched in
      # @param entity [Bluebook::Entity] the entity type being located
      # @param command_name [String] the command name, quoted in a refusal
      # @param container [Runtime::Instance, Hash{Symbol => Object}] the record or
      #   element holding the list to search
      # @param args [Hash{String, Symbol => Object}] the offered command arguments,
      #   read for the element's own identity when `routed_identity` is nil
      # @param routed_identity [String, nil] the routing envelope's own identity
      #   string for this hop, matched directly instead of deriving one from `args`
      # @return [Hash{Symbol => Object}] a fresh copy of the located element; the
      #   owning list inside `container` is replaced with a fresh copy too
      # @raise [Runtime::UnknownVerb] if `owner` declares no list attribute for `entity`
      # @raise [Runtime::NotFound] if an identity part is absent from `args`
      #   (`routed_identity` nil only), or no element matches
      def element_of(root_aggregate, owner, entity, command_name, container, args, routed_identity = nil)
        entity_name = entity.hecks_name
        list_attr = owner.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_holds_no_list",
                                                                  aggregate: owner.hecks_name, entity: entity_name))

        wants = unless routed_identity
                  entity.identity_paths.map do |path|
                    head = path.to_s.split(".").first.to_sym
                    raw  = args[head] ||
                           raise(NotFound, RefusalWording.render_site("NotFound", "entity_element_no_identity",
                                                                      command: command_name, entity: entity_name,
                                                                      identity: Identity.reading(entity)))

                    # An identity offered for addressing, not for storage
                    # (BUG#3, found live by `bin/qa_sweep` — banking fuzz seed
                    # 23, `LedgerEntry.Amend sequence: { value: 0 }` against an
                    # entry-less ledger). Coercing it all the way to a typed
                    # `Value` here ran that type's own invariant before this
                    # method ever checks whether any element matches — a
                    # `sequence: 0` against `LedgerSequence`'s own "a ledger
                    # sequence is positive" invariant raised InvariantViolation,
                    # not NotFound, even when (as here) nothing was ever posted
                    # at all. Every element actually in the list already
                    # satisfied its own type's invariant the moment it was
                    # created, so a value that fails it can never equal one —
                    # degrading to `UNMATCHABLE` here, instead of propagating,
                    # is exactly as safe as the ordinary "no match found" case
                    # below, and lines this addressing path up with the two
                    # conventions it already disagreed with: Rust's own
                    # `extract_id`/`extract_wants` (a raw scalar read, never a
                    # typed rebuild — rust/src/generated/*/*.rs) and
                    # `Identity.from`'s own raw-comparison convention for a
                    # root aggregate's identity (this file's sibling,
                    # `identity.rb`). `raw` rides alongside `want` so the
                    # eventual NotFound below can still quote what was offered.
                    want = begin
                      Value.for_attribute(root_aggregate, entity.attribute(head), raw)
                    rescue InvariantViolation
                      UNMATCHABLE
                    end

                    [head, path, want, raw]
                  end
                end

        original = Array(container[list_attr.name])
        position = if routed_identity
                     original.find_index { |element| element_identity(entity, element).to_s == routed_identity.to_s }
                   else
                     original.find_index do |el|
                       wants.all? { |head, _path, want, _raw| want != UNMATCHABLE && el[head] == want }
                     end
                   end
        unless position
          raise NotFound, RefusalWording.render_site(
            "NotFound", "entity_element_missing",
            entity: entity_name, identity: Identity.reading(entity),
            wants: wants&.map { |_h, path, _want, raw| Identity.scalar(path, raw) }&.join(", "),
            aggregate: owner.hecks_name,
            parent_id: container.respond_to?(:id) ? container.id.inspect : Rendering.describe(container)
          )
        end

        # One level deeper than Instance#dup, for the same reason: a list
        # attribute holds Hashes, and `apply_to_element` mutates the found
        # one in place — the update mechanism for an entity, not a bug. But
        # in place means aliased with the adapter's own record until this
        # copies the array and the target element before handing either
        # back, and writes the fresh array into `container` so the copy is
        # what persists on success and nothing aliased survives a refusal.
        # `container[list_attr.name] = copied` reaches `instance` itself
        # when this is the first hop, and reaches the (already copied)
        # parent element when it is a later one — either way it is the
        # same already-fresh object `locate_chain` is about to hand back
        # as `container` for the next hop, so nothing further has to
        # propagate a write back up the chain by hand.
        copied  = original.dup
        element = copied[position].dup
        copied[position] = element
        container[list_attr.name] = copied
        element
      end

      # The element's own identity, joined from its parts — the entity-level
      # twin of `Identity.of`, reading off the stored element (a Hash) rather
      # than a dispatch payload. An id is a scalar, and the path is how it is
      # reached — never by opening a value object and taking whatever single
      # field is inside. That unwrapping is gone from the language: a piece
      # that does not name its fields is refused when the bluebook loads ("an
      # entity says what it is known by", "an identity part names something"),
      # so by the time a dispatch arrives here there is always a path to dig.
      #
      # @param entity [Bluebook::Entity] the entity type whose identity paths
      #   are read
      # @param element [Hash{Symbol => Object}] the stored element to read an
      #   identity off
      # @return [String] the element's identity, joined from its declared parts
      def element_identity(entity, element)
        parts = entity.identity_paths.map do |path|
          head = path.to_s.split(".").first.to_sym
          Identity.scalar(path, element[head])
        end

        Naming.identity(parts)
      end

      # S17, ADR 0026 — `:append`/`:remove`/`:multiply`/`:clamp`, an
      # entity-scoped mirror of `CommandInterpreter::MutationApplier
      # #apply`'s own four (that module's own header names each one's
      # origin). Missing until now — an entity-owned command declaring
      # `sets :some_list, append: {...}` matched no `when` here and
      # silently no-opped, the one place this language otherwise
      # refuses what it cannot check applying nothing instead. `Member`/
      # `Dispatch` (S17) are the first real callers: both need to
      # append a value-object-typed element (`Pair`/`Binding`) onto a
      # list attribute they own, once they become entities of
      # `ValueObject`/`ProcessManager` rather than separate aggregates.
      #
      # `:increment`/`:decrement`/`:multiply` also fixed here, found
      # while proving this method against a real fixture: they wrapped
      # `amount` unconditionally whenever `attribute` existed, the same
      # asymmetric-wrapping shape `MutationApplier#rewrap_arithmetic_
      # result`'s own comment documents fixing at the aggregate level
      # (migration plan task 9) — a phantom-created VO-typed field's
      # `current` reads back a raw, unwrapped default, `amount` was
      # wrapped anyway, and the two sides of one arithmetic call
      # disagreed on Value-ness. Confirmed live, not theoretical: this
      # method's own fixture (TaggedList.Bump, a VO-typed `count` with
      # `default: 0`) raised exactly this TypeMismatch on its first
      # real run.
      # A case dispatching over a closed, declared set of mutation ops —
      # deliberately kept byte-for-byte parallel to its aggregate-level
      # twin, MutationApplier#apply (see this method's own comment
      # above and each branch's "own entity-scoped twin" cross-reference):
      # extracting the near-duplicate increment/decrement/multiply
      # shape here without doing the same there would break that
      # intentional mirroring, which is what lets the two be diffed
      # against each other when one gets a fix the other needs too.
      # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity
      # Applies one declared mutation to an entity element, in place.
      #
      # `pre` — the element as it was before this command (C4.2): every
      # read below goes through it, every write lands on `element`.
      #
      # @param rules [Runtime::CommandRules] the shared rules engine `resolve_source`/
      #   `arithmetic`/`multiply`/`clamp`/`sign_of` are read through
      # @param aggregate [Bluebook::Aggregate] the root aggregate, for value-object
      #   coercion
      # @param entity [Bluebook::Entity] the entity type `element` is an instance of
      # @param element [Hash{Symbol => Object}] the element to mutate; written in place
      # @param mutation [Bluebook::Mutation] the declared mutation to apply
      # @param args [Hash{String, Symbol => Object}] the offered command arguments,
      #   a mutation's source may read from
      # @param pre [Hash{Symbol => Object}] the element as it stood before this
      #   command; every read goes through this, every write lands on `element`
      # @return [void]
      # @raise [Runtime::TypeMismatch] if a mutation's own value cannot be coerced,
      #   or an arithmetic op's operands are not numeric or compatible value objects
      # @raise [Runtime::InvariantViolation] if a coerced or arithmetic-derived value
      #   object breaks one of its own invariants
      # @raise [Runtime::AlreadyExists] if an `:append` mints a nested entity whose
      #   identity collides with an existing element
      # @raise [Bluebook::Expression::EvaluationError] if an arithmetic op's product
      #   does not fit a signed 64-bit Integer, or is a non-finite Float
      # @raise [Runtime::WiringError] if `mutation.op` names no handled mutation kind
      def apply_to_element(rules, aggregate, entity, element, mutation, args, pre = element)
        case mutation.op
        when :set
          value = rules.resolve_source(mutation.source, args)
          attribute = entity.attribute(mutation.target)
          element[mutation.target] = attribute ? Value.for_attribute(aggregate, attribute, value) : value
        when :append
          element[mutation.target] = appended_to_element(aggregate, entity, pre, mutation, args)
        when :remove
          element[mutation.target] = removed_from_element(rules, aggregate, entity, pre, mutation, args)
        when :increment, :decrement
          attribute = entity.attribute(mutation.target)
          amount    = rules.resolve_source(mutation.source, args)
          current   = pre[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = rules.arithmetic(current, amount, mutation.target, rules.sign_of(mutation.op))
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :multiply
          attribute = entity.attribute(mutation.target)
          amount    = rules.resolve_source(mutation.source, args)
          current   = pre[mutation.target]
          amount    = Value.for_attribute(aggregate, attribute, amount) if attribute && current.is_a?(Value)
          result    = rules.multiply(current, amount, mutation.target)
          element[mutation.target] = rewrap_arithmetic_result(aggregate, attribute, current, result)
        when :clamp
          element[mutation.target] = rules.clamp(pre[mutation.target], mutation.source, mutation.target)
        # `corrects` — BUG#30. `MutationApplier#apply`'s own aggregate-
        # level `:corrects` branch's own comment gives the full reasoning;
        # the same one applies here unchanged: this mutation targets no
        # field on this element at all — its own event name, and whether
        # the owning record has actually emitted it, was already checked
        # once, up front, by `EntityInterpreter#step_enforce_givens`
        # (`CommandRules::Admissibility#enforce_correction_target`, called
        # there against the parent record/root aggregate — see that
        # step's own comment for exactly why). Whatever field a correction
        # actually changes is an ordinary declared `sets`/`increment`/etc.
        # mutation of its own, applied by one of the branches above like
        # any other — `qa/stress_domains/corrections`' own `Entry.Amend`
        # pairs `corrects "EntryRecorded", ...` with a separate `sets
        # :amount`, exactly this shape.
        when :corrects
          nil
        else
          # The aggregate-level twin's own backstop
          # (MutationApplier#apply), for the same reason: applying
          # nothing and refusing nothing would be the one silent
          # no-op in a language that otherwise refuses what it cannot
          # check.
          raise WiringError, "no entity mutation applier handles :#{mutation.op} — add one before declaring it"
        end
      end

      # Rewraps a plain-Numeric arithmetic result into `attribute`'s own declared
      # value-object type, when the arithmetic itself ran unwrapped.
      #
      # `MutationApplier#rewrap_arithmetic_result`'s own entity-scoped
      # twin, byte-for-byte the same fix — see that method's own
      # comment for the full "phantom-field asymmetric wrapping" story.
      # A no-op whenever `current` was already a Value (the arithmetic
      # call already returned one) or the mutation targets no declared
      # attribute at all.
      #
      # @param aggregate [Bluebook::Aggregate] the root aggregate, for value-object
      #   coercion
      # @param attribute [Bluebook::Attribute, nil] the mutated field's own declared
      #   attribute; a no-op when nil (targets no declared attribute)
      # @param current [Object] the field's pre-mutation value, as read off `pre`
      # @param result [Object] the arithmetic op's own result
      # @return [Runtime::Value, Object] `result` unchanged when already a `Value`,
      #   `current` is a `Value`, or `attribute` is nil; otherwise `result` coerced
      #   into `attribute`'s own declared type
      def rewrap_arithmetic_result(aggregate, attribute, current, result)
        return result if current.is_a?(Value) || attribute.nil? || result.is_a?(Value)

        Value.for_attribute(aggregate, attribute, result)
      end

      # Resolves an `:append` mutation's own field source against the offered
      # arguments, falling back to the element's own current field.
      #
      # `MutationApplier#resolve_append_source`'s own entity-scoped
      # twin — a caller-supplied arg first, falling back to the
      # element's own current field (never the parent instance's) when
      # it isn't one.
      #
      # @param source [Symbol, Object] the mutation's own field source: a Symbol
      #   names a command argument or, failing that, an element field; anything
      #   else is returned as is
      # @param element [Hash{Symbol => Object}] the element to fall back to reading
      #   from
      # @param args [Hash{String, Symbol => Object}] the offered command arguments
      # @return [Object, nil] the named argument's value; failing that, the named
      #   element field's value; `source` itself when it is not a Symbol
      def resolve_element_append_source(source, element, args)
        return source unless source.is_a?(Symbol)
        return args[source] if args.key?(source)

        element[source]
      end

      # `MutationApplier#appended`'s own entity-scoped twin. Usually a
      # value object element — an entity's own list, appended to by an
      # entity-owned command, holds a value object (`Member.pairs`'
      # own `Pair`, `Dispatch.with_spec`'s own `Binding`) the same way
      # most real corpus appends do — but entity-in-entity nesting (a
      # list of another entity, owned by this one) is real now too:
      # `qa/stress_domains/nested_pieces` (`Board.AddCard`, appending a
      # `Card` onto `Board`'s own `cards`) is the first corpus member to
      # do it, the comment this replaces having been written before that
      # domain existed. `element_type` naming an entity rather than a
      # value object falls through to `fields` unchanged, same as
      # before — `MutationApplier#entity_element`'s own identity-minting
      # fallback still isn't mirrored here (nothing in this corpus needs
      # auto-minting at this depth — Card supplies its own identity in
      # the append mapping) — but its collision-checking fallback now is
      # (BUG#145, `check_entity_collision`, below — see its own call
      # site's comment for why "collision-checking a nested entity is its
      # own separate, unfixed question," this comment's own prior wording,
      # stopped being true). BUG#12's fix (below) is likewise shared:
      # every declared attribute the append mapping doesn't name gets its
      # own default the same way a fresh aggregate's own attributes
      # already do (`Instance.defaults`), whichever branch built `fields`.
      #
      # @param aggregate [Bluebook::Aggregate] the root aggregate, for value-object
      #   coercion
      # @param entity [Bluebook::Entity] the entity type `element`'s mutated list
      #   attribute belongs to
      # @param element [Hash{Symbol => Object}] the element being appended to, read
      #   as the source for a field the mutation's own map does not supply directly
      # @param mutation [Bluebook::Mutation] the declared `:append` mutation
      # @param args [Hash{String, Symbol => Object}] the offered command arguments
      # @return [Array] `element[mutation.target]`'s existing elements, frozen deep,
      #   with the newly built element (a `Runtime::Value`, or a Hash for an entity
      #   or untyped element) appended last
      # @raise [Runtime::AlreadyExists] if the appended element is a nested entity
      #   whose identity collides with an existing one
      def appended_to_element(aggregate, entity, element, mutation, args)
        fields       = mutation.source.transform_values { |source| resolve_element_append_source(source, element, args) }
        element_type = entity.attribute(mutation.target)&.type
        value_object = aggregate.value_object(element_type)
        value_object&.attributes&.each do |attribute|
          fields[attribute.name] = Value.scalar(fields[attribute.name]) if fields[attribute.name].is_a?(Value)
        end
        appended =
          if value_object
            Value.build(value_object, fields, aggregate)
          else
            # `entity.entities`, not `aggregate.entities` — a piece
            # nested inside a piece is a child of the owning entity
            # (`Card` is `Board.entities`, never `Workspace.entities`;
            # `Behaviour::Entity#entities` answers direct children only,
            # by design — see its own comment), the same lexical-nesting
            # rule `EntityBuilder#entity_impl` builds the tree with in
            # the first place.
            nested_entity = entity.entities.find { |piece| piece.hecks_name == element_type.to_s }
            if nested_entity
              # BUG#145 — `MutationApplier#entity_element`'s own
              # `check_entity_collision` call (one hop up, an aggregate's
              # own entity list) never had a twin here: a nested entity's
              # own identity is always caller-supplied at this depth
              # (`Card.sequence` rides the append mapping directly — no
              # nested-entity auto-mint exists anywhere in this corpus,
              # see this method's own header), so this is unconditional,
              # unlike `#entity_element`'s own auto-mint/collision `if`/
              # `else` split — there is no auto-mint branch here to skip.
              # Found live: `qa/stress_domains/nested_pieces`'s own
              # differential sweep, `Board.AddCard` dispatched twice under
              # the same `sequence` — Ruby silently appended a second
              # `Card`, Rust's generated code (`rust/project/mutations.rb`'s
              # `emit_mutation_line_body`, which never splits an
              # aggregate-owned append from an entity-owned one the way
              # this runtime's two separate methods do) already refused
              # `AlreadyExists` for both depths.
              # `entity` (the owner — `Board`), not `aggregate` (the root
              # — `Workspace`), is what the refusal names as "on {…}" —
              # `check_entity_collision`'s first argument is only ever
              # used for that one naming purpose (`owner.hecks_name`,
              # below), matching Rust's own generated wording exactly
              # (`rust/project/mutations.rb`'s own `collision_guard`
              # passes the entity's declaring construct's name the same
              # way — "a Card already exists on Board", never "…on
              # Workspace").
              check_entity_collision(entity, nested_entity, element[mutation.target], fields)
              fill_declared_defaults(aggregate, nested_entity, fields)
            else
              fields
            end
          end
        Freezer.deep(Array(element[mutation.target]) + [appended])
      end

      # BUG#12 — an entity created via `sets :list, append: {...}` used
      # to leave any of its own declared attributes the append mapping
      # simply didn't name (an optional field a later, separate command
      # sets — `Board.label`, `Card.note`) absent from the stored hash
      # entirely, not even a `nil` placeholder, until that later command
      # actually ran. `rust/project/json_codec.rb#emit_to_json_flat`'s
      # own header comment documents the opposite as the intended
      # contract for a persisted record: every declared field present,
      # `null` when unset, "because Ruby's own `JSON.generate(state)`
      # round-trip this mirrors does the same" — true for a freshly
      # created aggregate (`Instance.defaults` already fills one key per
      # declared attribute, `default_for` per attribute), never true for
      # an entity minted by an append. This closes that gap the same
      # way: `Instance.default_for` is the same per-attribute default
      # rule (nil with no declared `default:`, a fully-defaulted value
      # object when every one of its own fields has one), reused rather
      # than reimplemented so the two creation paths can never drift on
      # what "the default" means. Additive only — a key `fields` already
      # holds (the append mapping, an auto-minted identity, a lifecycle
      # default) is never overwritten.
      #
      # @param aggregate [Bluebook::Aggregate] the root aggregate, for value-object
      #   coercion
      # @param entity [Bluebook::Entity] the entity type whose declared attributes
      #   are defaulted
      # @param fields [Hash{Symbol => Object}] the element fields already resolved;
      #   written in place
      # @return [Hash{Symbol => Object}] `fields`, with every declared attribute it
      #   did not already hold filled with its own default
      def fill_declared_defaults(aggregate, entity, fields)
        entity.attributes.each do |attribute|
          next if fields.key?(attribute.name)

          fields[attribute.name] = attribute.list? ? Freezer.deep([]) : Instance.default_for(aggregate, attribute)
        end
        fields
      end

      # `MutationApplier#removed`'s own entity-scoped twin — matches by
      # value equality, element-wise, the same "so a concurrent Add can
      # never be lost" reasoning that method's own comment gives, unless
      # the list this targets is itself entity-typed — see
      # `list_element_match?`, below, which both this and
      # `MutationApplier#removed` now share.
      #
      # @param rules [Runtime::CommandRules] the shared rules engine `resolve_source`
      #   is read through
      # @param aggregate [Bluebook::Aggregate] the root aggregate, for value-object
      #   coercion
      # @param entity [Bluebook::Entity] the entity type `element`'s mutated list
      #   attribute belongs to
      # @param element [Hash{Symbol => Object}] the element being removed from
      # @param mutation [Bluebook::Mutation] the declared `:remove` mutation
      # @param args [Hash{String, Symbol => Object}] the offered command arguments
      # @return [Array] `element[mutation.target]`'s existing elements, with any
      #   matching the resolved remove target left out
      def removed_from_element(rules, aggregate, entity, element, mutation, args)
        value     = rules.resolve_source(mutation.source, args)
        attribute = entity.attribute(mutation.target)
        value     = Value.for_attribute(aggregate, attribute, value) if attribute
        Array(element[mutation.target]).reject { |candidate| list_element_match?(aggregate, attribute, candidate, value) }
      end

      # BUG#32 (QualityControl ledger) — the match rule `remove:` uses
      # against one stored list element. Value equality for a
      # value-object-typed list stays exactly what it always was — an
      # element and `value` are both real `Value`s there, so `==` already
      # compares every field, the "concurrent Add can never be lost"
      # shape `removed`/`removed_from_element`'s own headers describe.
      # An entity-typed list is different in kind, not just in type: a
      # stored element is a plain Hash, never a `Value` (`Entity`'s own
      # header — "an entity must never answer .value_object"), so there
      # is no whole-value shape to compare against at all — only the
      # entity's own identity field, the same field a caller already has
      # to name to address that element any other way
      # (`element_of`'s own `wants`, above). `value` arrives here already
      # coerced against that identity field's declared type
      # (`Coercion#hydrate_entity_identity`, run underneath
      # `Value.for_attribute` before either caller above ever sees it),
      # so this only has to know which field to read off the stored
      # element — `entity.identity_heads`'s own single head, when there
      # is exactly one. A composite identity (more than one head, or
      # none) has no single field a bare `remove:` target could mean —
      # this returns `false` (never a match, the same documented no-op
      # `hydrate_entity_identity`'s own header already commits to) rather
      # than guessing which head, matching the narrow, honest boundary
      # `MutationApplier#check_entity_collision`'s own header draws for
      # entity identity elsewhere in this runtime.
      #
      # Shared by `MutationApplier#removed` (an aggregate's own list) and
      # `#removed_from_element` (a list an entity owns), so the two
      # `remove:` call sites can never quietly disagree on what
      # "matches" means — the same reasoning this file's own header
      # gives for centralizing `locate_chain`/`element_of` once rather
      # than twice.
      #
      # @param aggregate [Bluebook::Aggregate] the root aggregate, to resolve
      #   whether `attribute`'s own type is an entity
      # @param attribute [Bluebook::Attribute, nil] the list attribute `element`
      #   belongs to
      # @param element [Object] the stored list element to check: a Hash for an
      #   entity-typed list, a `Runtime::Value` otherwise
      # @param value [Object] the `remove:` target to match `element` against
      # @return [Boolean] whole-value equality for a non-entity-typed list;
      #   identity-field equality for an entity-typed one with a single identity
      #   head; false for a composite or absent identity
      def list_element_match?(aggregate, attribute, element, value)
        entity = attribute&.list? ? Value.find_entity(aggregate, attribute.type.to_s) : nil
        return element == value unless entity

        head = entity.identity_heads.one? ? entity.identity_heads.first : nil
        return false unless head

        element.is_a?(Hash) && element[head] == value
      end

      # Refuses a caller-supplied or composite identity that already names an
      # element on `current`.
      #
      # BUG#13 — the same check #hydrate gives every creating
      # aggregate command (`repository.find(id)`,
      # `command_interpreter.rb`), one level down. Shared with
      # `MutationApplier` (mutation_applier.rb), called from
      # `#entity_element` — an aggregate's own entity list (`Workspace.
      # boards`, `Ledger.entries`) — and, moved here (BUG#145), from `#appended_
      # to_element`, above — an entity's own nested entity list one hop
      # further in (`Board.cards`) — so neither call site reimplements
      # it a second time, the same way `#list_element_
      # match?` already avoids that split for `remove:`.
      #
      # Reached, at the aggregate-owned call site, only on the two
      # branches that do not auto-mint: a caller-supplied identity (the
      # field is already in the append's own field map) or a composite
      # one (`entity.identified_by` is nil for those — Runtime::
      # Identified#derive_identity). Without this, neither checks the sibling
      # list at all: a second LogVisit with the same date+sequence, or a
      # second IssueKey with the same serial, would append a silent
      # duplicate — worse than an ordinary duplicate row, because
      # `EntityElement#element_of`'s own `find_index` always matches the
      # first match, so the second becomes permanently unaddressable by
      # any later command. At the entity-owned call site (`#appended_to_
      # element`), there is no auto-mint branch at all — every caller
      # reaches this unconditionally, since a nested entity's own
      # identity is always caller-supplied in this corpus.
      #
      # Auto-minted (aggregate-owned) entities never reach here —
      # `identity_heads` for them is still checked at mint time by
      # construction (`current.size + 1` can only repeat if something
      # `remove:`s from the list between mints, which no real domain does
      # today), so they can't be flagged by mistake.
      # `owner` — the declaring construct named in the "…already exists on
      # {owner}" wording: the root aggregate at the aggregate-owned call
      # site (`Workspace`, `Ledger`), the immediately-enclosing entity at
      # the entity-owned one (`Board` — never the root `Workspace` two
      # hops up). Used for that naming purpose only (`owner.hecks_name`) —
      # never for `Value`/namespace resolution, which is why an `Entity`
      # (not just an `Aggregate`) is a valid thing to pass here.
      #
      # @param owner [Bluebook::Aggregate, Bluebook::Entity] the construct named
      #   in a refusal as what the duplicate "already exists on"
      # @param entity [Bluebook::Entity] the entity type being checked for a
      #   colliding identity
      # @param current [Array<Hash>, Object] the entity's own existing elements;
      #   coerced through `Array()`, so a single element or nil is also accepted
      # @param fields [Hash{Symbol => Object}] the new element's own fields, whose
      #   identity heads are checked against every element in `current`
      # @return [void]
      # @raise [Runtime::AlreadyExists] if `current` already holds an element
      #   whose identity heads match `fields`'s own
      def check_entity_collision(owner, entity, current, fields)
        heads = entity.identity_heads
        return if heads.empty?

        collision = Array(current).find { |element| heads.all? { |head| element[head] == fields[head] } }
        return unless collision

        raise(AlreadyExists, RefusalWording.render_site("AlreadyExists", "entity_duplicate",
                                                        entity: entity.hecks_name, aggregate: owner.hecks_name,
                                                        identity: Identity.reading(entity),
                                                        offered: heads.map { |head| Rendering.describe(fields[head]) }))
      end
    end
  end
end
