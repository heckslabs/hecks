require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../../rendering"

module Hecks
  module Runtime
    class Value
      # HOW A `list_of` ATTRIBUTE'S OWN ELEMENTS GET HYDRATED — entity-typed
      # and value-object-typed alike — split out of `Coercion` (this file's
      # sibling, extended into `Value` alongside it exactly the way
      # `Admission` already is) once `Coercion` itself grew past
      # `Metrics/ModuleLength`'s budget from two, unrelated fixes landing in
      # the same method the same week (BUG#32's own `hydrate_entity_identity`
      # and BUG#33's own `check_entity_list_identities` — see each method's
      # own header, and this repo's `.rubocop_todo.yml` for the merge that
      # made the split necessary). Cross-calls into `Coercion`'s own
      # `for_attribute`/`build`/`fields_for`/`value_object_for`/
      # `trusting_stored_state?` work unqualified here exactly as they did
      # before the split, because both modules land on the SAME `Value`
      # singleton class once extended — `self` never has to know which file
      # a sibling method actually lives in.
      module EntityListCoercion
        # S17, ADR 0026 — SEARCHES THE WHOLE ENTITY TREE, not only the
        # root's own direct children. `aggregate` here is always the
        # ROOT aggregate — `for_attribute`'s own `aggregate` argument is
        # never reassigned as hydration recurses into a nested element,
        # because coercion has to resolve value objects, and only the
        # root answers `.value_object` at all (Entity's own header
        # comment: an entity must NOT answer to it, or `Value.
        # for_attribute` could no longer tell a piece from a head). So
        # a NESTED entity — Dispatch, inside Handler — is not a direct
        # child of the root the way Handler itself is, and a plain
        # `aggregate.entities.find` stops one level short of it.
        def find_entity(construct, name)
          construct.entities.each do |candidate|
            return candidate if candidate.hecks_name == name

            found = find_entity(candidate, name)
            return found if found
          end
          nil
        end

        # Frozen through: a list read back out of the store is an answer,
        # not a handle on what is stored.
        #
        # ADR 0047 — this used to bail (`return value unless entity`) the
        # moment `attribute.type` named a value object rather than an
        # entity, handing back the raw, un-hydrated argument untouched.
        # A `sets :field` mutation sourced from a whole-array argument (as
        # opposed to element-by-element `append:`) went straight through
        # `for_attribute`'s `:list` branch, so `Banking::CardPayment.
        # Authorize`'s own `sets :tags` (`list_of(Tag)`) stored plain
        # Ruby Hashes as its `tags` elements forever — never a real
        # `Value`, never through `Tag`'s own `pattern:`/`invariant`
        # checks. `remove:`'s `==` comparison (a real `Value` against a
        # raw `Hash`) then always failed, since `Hash#==` refuses anything
        # that isn't itself a compatible Hash — the bug ADR 0047 traces in
        # full. Delegating to `hydrate_value_object_list` below closes
        # that gap the same way the ENTITY branch already worked: build a
        # real, validated `Value` per element, reusing `for_attribute`'s
        # own composite-construction path rather than inventing a second
        # one.
        # BUG#32 (QualityControl ledger) — `remove:`'s own single-target
        # value used to fall straight into `Array(value).map { ... }`
        # below UNGUARDED, unlike this method's own delegated
        # `hydrate_value_object_list` sibling, whose `value.is_a?(Array)`
        # check exists for exactly this shape (see that method's own
        # comment). For an ENTITY-typed list, `remove:`'s scalar target
        # (`Ledger.Void`'s `sequence: EntrySequence`) is never a Hash, so
        # `Array(2)` merely wrapped it as `[2]` rather than shredding it —
        # but the wrapping itself was still wrong: `MutationApplier#
        # removed`'s `element == value` then compared a stored `Entry`
        # Hash against a one-element Array, which can never be `==` a
        # Hash, so nothing was ever removed and nothing ever refused
        # either. Routed to `hydrate_entity_identity` instead, below.
        def hydrate_entity_list(aggregate, attribute, value)
          entity = find_entity(aggregate, attribute.type.to_s)
          return hydrate_value_object_list(aggregate, attribute, value) unless entity

          return hydrate_entity_identity(aggregate, entity, value) unless value.is_a?(Array)

          hydrated = value.map do |element|
            next element unless element.is_a?(Hash)

            element.each_with_object({}) do |(name, field_value), acc|
              key = name.to_sym
              field = entity.attribute(key)
              acc[key] = field ? for_attribute(aggregate, field, field_value) : field_value
            end
          end
          # BUG#33 — only a genuine WHOLE-LIST offering (`value.is_a?(Array)`)
          # is a caller naming every element's own identity at once; the
          # single-target shape this same method also hydrates (a `remove:`
          # target, wrapped one level up by `Array()`) never reaches this
          # check, and never should — see `check_entity_list_identities`'s
          # own comment.
          check_entity_list_identities(aggregate, entity, hydrated) if value.is_a?(Array)
          Freezer.deep(hydrated)
        end

        # `MutationApplier#check_entity_collision`'s own guard
        # (mutation_applier.rb), extended from a single caller-supplied
        # APPEND (BUG#13) to a whole-list REPLACE — `sets :entries` bare
        # (`Ledger.ReplaceEntries`, the corpus's first `list_of(ENTITY)`
        # command argument/mutation, qa/stress_domains/corrections). The
        # array branch above rebuilds each offered element's own declared
        # fields but never checked the OFFERED LIST ITSELF for either way
        # it can misname its own entities:
        #
        #   - two elements sharing one identity — the same silent-duplicate
        #     hazard BUG#13's own comment describes: `EntityInterpreter#
        #     element_of`'s own `find_index` always matches the FIRST
        #     match, so the second becomes permanently unaddressable by any
        #     later command.
        #   - an element missing its identity altogether — there is no
        #     auto-mint for a whole-list replace the way `MutationApplier#
        #     entity_element` mints one for a single append (which element
        #     would it mint for? every element here is the caller's own
        #     whole state, offered at once), so an absent identity is
        #     refused rather than guessed.
        #
        # NON-COMPOSITE identities only, exactly BUG#13's own scope
        # (`entity.identified_by` answers a single Symbol only when
        # `identity_heads.size == 1`, `Behaviour::Traits#derive_identity`) —
        # a composite identity's own duplicate/missing question is the
        # same pre-existing, narrower gap BUG#13 documented and left open,
        # not widened here.
        #
        # SKIPPED under `trusting_stored_state?`, the same guard `validate!`
        # already gives every value object (C6.3): a record already
        # written is trusted as it was, so tightening this check can never
        # make an old, already-persisted record unreadable.
        def check_entity_list_identities(aggregate, entity, elements)
          identity = entity.identified_by
          return unless identity
          return if trusting_stored_state?

          field = entity.attribute(identity)
          seen  = []
          elements.each do |fields|
            next unless fields.is_a?(Hash)

            offered = fields[identity]
            if offered.nil?
              raise TypeMismatch,
                    RefusalWording.render("TypeMismatch", "numeric_field",
                                          type: entity.hecks_name, field: identity,
                                          expected: field&.type, offered: "nil")
            end

            if seen.include?(offered)
              raise AlreadyExists,
                    RefusalWording.render("AlreadyExists", "entity_duplicate",
                                          entity: entity.hecks_name, aggregate: aggregate.hecks_name,
                                          identity: entity.identity_paths.join(", "),
                                          offered: Rendering.describe(offered))
            end
            seen << offered
          end
        end

        # BUG#32 — `remove:`'s own single-target value against an
        # ENTITY-typed list. An entity is never offered to `remove:`
        # WHOLE the way a value object is (`hydrate_value_object_list`'s
        # own `element == value` full-value-equality shape) — an entity
        # must never answer `.value_object` at all (`Entity`'s own header
        # comment), so there is no whole-value shape here to rebuild in
        # the first place, only the ONE field a caller would otherwise
        # have to NAME to address that element any other way
        # (`EntityElement#element_of`'s own `wants`). So this coerces the
        # offered scalar against the entity's OWN identity field's
        # declared type — not the entity's full shape — and hands back a
        # real, correctly-typed `Value` ready to compare against each
        # stored element's own identity field
        # (`EntityElement.list_element_match?`, the shared rule both
        # `MutationApplier#removed` and `EntityElement#
        # removed_from_element` match against).
        #
        # A COMPOSITE identity (more than one head) has no single field a
        # bare `remove:` target could mean, so this passes the value
        # through UNCOERCED rather than guessing which head — the same
        # "nothing in this corpus needs it yet" boundary
        # `MutationApplier#check_entity_collision`'s own header already
        # draws for entity identity elsewhere in this runtime.
        # `list_element_match?` treats an uncoerced value the same way
        # it always treated the pre-fix wrapped Array: never a match, a
        # documented no-op rather than a crash.
        def hydrate_entity_identity(aggregate, entity, value)
          return value if value.is_a?(self)

          heads = entity.identity_heads
          return value unless heads.one?

          field = entity.attribute(heads.first)
          return value unless field

          for_attribute(aggregate, field, value)
        end

        # The value-object sibling of the entity branch above: an element
        # already shaped like the target `Value` (or a `Hash`/scalar that
        # `fields_for` can still open) is rebuilt through the SAME `build`
        # a scalar composite attribute already uses (`for_attribute`'s own
        # `coerced = ... build(value_object, fields_for(...), aggregate)`
        # line) — same defaults, same `pattern:`/`admits:`/invariant
        # checks, same `trusting_stored_state?` bypass on a trusted load.
        # `attribute.type` naming neither an entity nor a value object
        # (a `list_of(String)`, say) has no shape to rebuild into, so the
        # element passes through unchanged, exactly as the entity branch's
        # own non-Hash elements do.
        #
        # NOT `Array(value).map` (unlike the entity branch above) — `value`
        # here is not always genuinely list-shaped. `MutationApplier#
        # removed`'s own `Value.for_attribute(aggregate, attribute, value)`
        # call (`attribute` = the LIST attribute, `mutation.target`; `value`
        # = the single REMOVE-target argument, already a real `Value` by
        # the time it gets here) reuses this exact branch — for `remove:`,
        # not for a whole-list `sets`. `Array(a_real_Value)` alone would be
        # harmless (`Value` defines neither `to_a` nor `to_ary`, so Kernel
        # wraps it `[value]`), but `Array(a_Hash)` is NOT harmless: Ruby's
        # `Array()` opens a bare Hash into its own `[[k, v], ...]` pairs,
        # not `[hash]` — silently shredding a single-element Hash-shaped
        # target into garbage instead of hydrating it. Branching on
        # `value.is_a?(Array)` up front (true only for a genuine whole-list
        # `sets`/hydrate load) keeps the single-target shape a single
        # target, hydrated the same way, never listified.
        def hydrate_value_object_list(aggregate, attribute, value)
          return value unless aggregate.respond_to?(:value_object)

          value_object = value_object_for(aggregate, attribute.type)
          return value unless value_object

          return hydrate_value_object_element(aggregate, attribute, value_object, value) unless value.is_a?(Array)

          hydrated = value.map { |element| hydrate_value_object_element(aggregate, attribute, value_object, element) }
          Freezer.deep(hydrated)
        end

        def hydrate_value_object_element(aggregate, attribute, value_object, element)
          return element if element.is_a?(self) && element.type_name == value_object.hecks_name

          build(value_object, fields_for(value_object, attribute.name, element), aggregate)
        end
      end
    end
  end
end
