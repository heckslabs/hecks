require_relative "../../bluebook/expression/evaluator"
require_relative "../../naming"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "invariant_violation"

module Hecks
  module Runtime
    class Value
      # The class-side engine: how a raw argument or stored field becomes a
      # typed Value. Extended into Value, so every method here reads as
      # `Value.for`, `Value.build`, … — `self` is the Value class.
      module Coercion
        # The four `SHAPES` an attribute's value can take — named here because
        # `for_attribute` immediately below is the one place that actually
        # branches on all four, and nowhere else in the language collects
        # them into a single closed list. `Attribute#list?`/`#optional?`
        # are real predicates on the IR node itself (bluebook/attribute.rb);
        # `:scalar` and `:composite` are not named predicates there — they
        # fall out of whether `aggregate.value_object(attribute.type)`
        # resolves to something, read directly in the `coerced =` line
        # below — but the branch is exactly as real, so it gets a name here
        # too rather than staying anonymous.
        #
        # A second runtime's kernel ports this method by hand (rust/src/
        # kernel/attribute_shapes/*.rs — one file per name in this array,
        # generated into a Rust enum by bin/project_kernel_capabilities so
        # every match over it is compiler-checked exhaustive). If a fifth
        # branch is ever added to `for_attribute`, add its name here in the
        # same breath — this list is that port's only source of truth for
        # "which shapes exist," and a shape missing from it is a shape the
        # generated Rust enum, and therefore the kernel, can never learn
        # about no matter how correct the Ruby below is.
        SHAPES = %i[scalar list optional composite].freeze

        # Coerces a raw value against the attribute an aggregate declares by name.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct to look
        #   `name` up on
        # @param name [String, Symbol] the attribute's declared name
        # @param value [Object] the raw value to coerce
        # @return [Object] `value` unchanged when `aggregate` declares no such attribute;
        #   otherwise the same result `for_attribute` gives
        # @raise [Runtime::TypeMismatch] if the coercion `for_attribute` performs refuses
        #   the value's shape
        # @raise [Runtime::InvariantViolation] if the coerced value violates the attribute's
        #   own invariants or closed set
        # @raise [Runtime::AlreadyExists] if a `list_of(Entity)` offering duplicates one
        #   entity's own identity
        def for(aggregate, name, value)
          attribute = aggregate.attribute(name)
          return value unless attribute

          for_attribute(aggregate, attribute, value)
        end

        # The four `SHAPES` above, in the order this method actually checks
        # them: `optional`/nil-passthrough first (a value that isn't there
        # has no shape left to branch on), `list` second (a list of
        # elements, hydrated as entities), then — inside `coerced =` —
        # `composite` (the type names a declared value object, rebuilt
        # recursively via `build`) with `scalar` as what's left once
        # neither of those applies (the raw value, passed through
        # unchanged).
        # `boundary: false` is the query door (`QueryInterpreter#normalize_args`):
        # a query attribute's declared type names the argument for callers and
        # generators, never a runtime shape — comparison unwraps both sides
        # itself, so a `reference: {value: ...}` offered against a `String`
        # query field is the documented allowance (see banking's own
        # `Account.OpenForCustomer`), not a C3.8 mismatch.
        # `argument: true` is the command/entity/port argument door only
        # (`Interpreting#normalize_args`, every command/entity/port
        # dispatch): the one place a nil for a non-optional attribute is
        # the caller leaving a required argument empty (C3.7), absorbed
        # via the type's own field defaults when every field has one
        # (`nil_argument` below). Every other caller — `sets` copying an
        # optional argument into state, hydration, entity elements,
        # identity, defaults — is state assembly, where nil is a
        # legitimate "absent is not empty" value the aggregate's own
        # attribute may hold. `QueryInterpreter#normalize_args` never
        # passes `argument: true` — a null required value-object-typed
        # query argument is checked, and refused, entirely on its own
        # side (`null_vo_argument!`, query_interpreter.rb) precisely so
        # it does not reach this default-absorbing fallback (QualityControl
        # BUG#36 — a query's own null VO argument must refuse regardless
        # of any default, unlike a command's).
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct that declares
        #   `attribute`, for resolving its value-object type
        # @param attribute [Bluebook::Attribute, nil] the declared attribute; nil is treated
        #   like a nil value
        # @param value [Object, nil] the raw value to coerce
        # @param boundary [Boolean] whether a bare-primitive attribute's runtime shape is
        #   checked (true) or only its declared type is used for callers/generators (false,
        #   the query door)
        # @param argument [Boolean] true only at the command/entity/port argument door,
        #   where a nil for a non-optional attribute is refused (or defaulted) rather than
        #   passed through as ordinary state assembly would
        # @return [Object, nil] the coerced value: unchanged for a reference or a bare
        #   primitive with no value-object type, a `Runtime::Value` for a composite
        #   attribute, an Array for a list; nil is possible via `nil_or_missing`/
        #   `nil_argument` (an optional attribute, or a load)
        # @raise [Runtime::TypeMismatch] if `argument` is true and a required field has no
        #   default, if a `has_many` value is not an Array, or if the coerced value's shape
        #   is refused
        # @raise [Runtime::InvariantViolation] if the coerced value violates its type's own
        #   invariants or closed set
        # @raise [Runtime::AlreadyExists] if a `list_of(Entity)` offering duplicates one
        #   entity's own identity
        def for_attribute(aggregate, attribute, value, boundary: true, argument: false)
          return nil_or_missing(aggregate, attribute, value, argument) if attribute.nil? || value.nil?
          return reference_list(attribute, value) if attribute.list? && attribute.reference?
          return reference_identity(attribute, value) if attribute.reference?
          return hydrate_entity_list(aggregate, attribute, value) if attribute.list? # :list
          return value unless aggregate.respond_to?(:value_object)

          # The set the attribute names is checked where the attribute is known.
          # `build` below sees only the value object, never which attribute asked
          # for it, so a command argument's `admits:` has to be read here — this
          # is the door every argument and every head field comes through.
          #
          # After coercion, not before: a scalar arrives wrapped in whatever holder
          # its type names (`{value: "append"}` for an OpName), and checking the
          # raw payload would be checking the envelope.
          value_object = value_object_for(aggregate, attribute.type)
          return bare_primitive(aggregate, attribute, value, boundary) if value_object.nil?

          coerced = if value.is_a?(self) && value.type_name == value_object.hecks_name
                      value
                    else
                      build(value_object, fields_for(value_object, attribute.name, value), aggregate)
                    end

          admit_declared_set(aggregate, attribute, coerced)
          coerced
        end

        # NIL is not a value for a non-optional argument (C3.7/C3.8). An
        # `optional:` attribute and a load from the store pass nil through
        # as they always did; a command argument offered as null for a
        # required attribute is
        # refused as the field the caller left empty — a value object is
        # built from no fields, so its first required field refuses with
        # exactly the wording the Rust side's `from_json` gives it
        # ("Money.cents expects Integer, got nil"), and a bare scalar
        # refuses through `check_bare_primitive`'s own wording. Lists and
        # references keep their nil passthrough (their absence is an empty
        # relationship, `validate_relationship_cardinality`'s business).
        # The `attribute.nil?`/`value.nil?` branch of `for_attribute`,
        # pulled out on its own — an unknown attribute has no shape left
        # to branch on, and a nil value is either an ordinary absence
        # (state assembly, hydration, a query ask) or, at the argument
        # door only, `nil_argument`'s own C3.7 refusal.
        private def nil_or_missing(aggregate, attribute, value, argument)
          return value if attribute.nil? || !value.nil?

          argument ? nil_argument(aggregate, attribute) : value
        end

        private def nil_argument(aggregate, attribute)
          return nil if attribute.optional? || trusting_stored_state?
          return nil if attribute.list? || attribute.reference?

          value_object = aggregate.respond_to?(:value_object) ? value_object_for(aggregate, attribute.type) : nil
          return build(value_object, {}, aggregate) if value_object

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "numeric_field",
                                           type: aggregate.hecks_name, field: attribute.name,
                                           expected: attribute.type, offered: "nil")
        end

        # A bare primitive is type-checked at the boundary too (C3.8,
        # docs/semantics/bluebook-semantics.md) — the same two predicates a
        # value object's own fields get, so wrong-typed caller input is a
        # TypeMismatch refusal here, never an evaluation fault later. Its
        # `admits:` set is still checked, exactly as a value object's is.
        private def bare_primitive(aggregate, attribute, value, boundary)
          check_bare_primitive(aggregate, attribute, value) if boundary
          admit_declared_set(aggregate, attribute, value)
          value
        end

        # Aggregate-local value objects remain authoritative, which permits
        # intentional duplication. An ordinary fact may also name an identity
        # value object declared on another aggregate; that shape is borrowed
        # only when every chapter declaration with the name agrees.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct to resolve
        #   `type` against first
        # @param type [String, Bluebook::TypeRef] the attribute's declared type
        # @return [Bluebook::ValueObject, nil] `aggregate`'s own value object of that name if
        #   it declares one; otherwise, when every chapter aggregate that declares one agrees
        #   on its shape, the first match; nil when `type` names no value object anywhere,
        #   or the chapter's own declarations of it disagree
        def value_object_for(aggregate, type)
          local = aggregate.value_object(type)
          return local if local

          chapter = aggregate.respond_to?(:hecks_owner) ? aggregate.hecks_owner : nil
          return nil unless chapter.respond_to?(:aggregates)

          matches = chapter.aggregates.filter_map { |candidate| candidate.value_object(type) }
          shapes = matches.group_by do |shape|
            shape.attributes.map { |field| [field.name, field.type.to_s, field.list?, field.optional?] }
          end
          shapes.size == 1 ? matches.first : nil
        end

        # Retained relationships store canonical target identities, not Ruby
        # Value wrappers. Raw scalar IDs remain a compatibility input. A named
        # identity VO omits its minted aggregate field at the command boundary;
        # a bespoke compound VO may instead name the target heads directly.
        # Neither form requires reverse-splitting a canonical ID.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute
        # @param value [Object] the offered value: a bare scalar, a `Runtime::Value`, or a Hash
        # @return [Object] a bare scalar or `Naming.identity`-joined String for a compound
        #   identity, ready to store; `value` unchanged if it is neither a `Runtime::Value`
        #   nor a Hash, if the attribute's target cannot be resolved, if the target declares
        #   no identity paths, or if no unambiguous scalar can be found for every path
        def reference_identity(attribute, value)
          return value unless value.is_a?(self) || value.is_a?(Hash)

          target = attribute.type.resolve
          return value unless target

          materialized = materialize(value)
          paths = target.identity_paths
          return value if paths.empty?

          direct_head = direct_identity_head(value, target)
          parts = paths.map { |path| identity_part(materialized, path, direct_head) }
          if parts.any? { |part| part.nil? || (part.respond_to?(:empty?) && part.empty?) }
            return sole_scalar_identity(value, paths) || value
          end

          Naming.identity(parts)
        end

        # A command may redeclare a `reference_to` field under its own,
        # differently-named single-attribute value object (`attribute
        # :venue, VenueHandle; sets :venue`, not `reference_to Venue` —
        # QualityControl BUG#121, `qa/stress_domains/generated_revalued_
        # shape`'s own `Hangar.Repoint`) instead of naming the target's
        # own identity field(s) directly. `identity_part`'s path walk
        # above only ever matches an incoming shape that already uses the
        # target's own field names (or is the target's own identity value
        # object, `direct_identity_head`) — an ad hoc wrapper around a
        # bare scalar under some other field name (`VenueHandle`'s own
        # `value`, not `Venue`'s own `code`) fails every path lookup.
        # Without this method to catch that case, it would fall through
        # to the unresolved `return value` above, storing the wrapped
        # Value — one reference field on one aggregate holding two
        # different shapes depending on which command last wrote it:
        # `Open`'s own bare `reference_to Venue` argument is never
        # wrapped in the first place (the top guard clause passes a bare
        # scalar straight through), so it always stores the canonical
        # bare identity this class's own header comment promises
        # ("canonical target identities, not Ruby Value wrappers"),
        # while `Repoint` would silently keep the wrapper instead.
        #
        # Unambiguous only when both sides admit exactly one scalar: the
        # target names exactly one identity path (`paths.one?` — a
        # compound identity has no single field either side could stand
        # in for) and the offered value is itself a single-attribute
        # value object (`sole_attribute` — a multi-field VO has no one
        # scalar to unwrap either). `materialize_unwrapped` recurses
        # through any further single-field wrapping the same way it
        # already does for `Value.materialize_unwrapped`'s other callers,
        # landing on the bare scalar `Open`'s own path already produces
        # for the identical target field.
        #
        # @param value [Object] the offered value, tried as a single-attribute `Runtime::Value`
        # @param paths [Array<String>] the target's own declared identity paths
        # @return [Object, nil] the unwrapped bare scalar when `value` is a single-attribute
        #   `Runtime::Value` and `paths` names exactly one path; nil otherwise
        def sole_scalar_identity(value, paths)
          return nil unless value.is_a?(self) && paths.one?
          return nil unless value.value_object.sole_attribute

          materialize_unwrapped(value)
        end

        # Whether `value` is itself the target's own (single) identity
        # value object — pure, self-contained: reads only `value` and
        # `target`, decides nothing about any particular path.
        #
        # @param value [Object] the offered value
        # @param target [Bluebook::Aggregate] the aggregate `attribute` references
        # @return [String, nil] the target's own single identity head, as a String, when
        #   `value` is a `Runtime::Value` of that head's exact declared type; nil when
        #   `target` has a compound identity, or `value` is not that type
        def direct_identity_head(value, target)
          return nil unless value.is_a?(self) && target.identity_heads.one?

          head = target.identity_heads.first
          target.attribute(head)&.type.to_s == value.type_name ? head.to_s : nil
        end

        # One identity path's own value out of the materialized hash —
        # stripping a leading segment already covered by
        # `direct_identity_head`, then walking the rest. Pure given its
        # three inputs; extracted from `reference_identity` alongside
        # `direct_identity_head` above purely to keep that method to its
        # own guard-clause shape.
        #
        # @param materialized [Hash, Object] the offered value, already materialized to plain
        #   data
        # @param path [String] one dotted identity path segment, such as `"customer.email"`
        # @param direct_head [String, nil] the leading segment `direct_identity_head` already
        #   matched, stripped before walking the rest
        # @return [Object, nil] the value found by walking `path` (minus `direct_head`) into
        #   `materialized`; nil if any segment is missing or the walk hits a non-Hash
        def identity_part(materialized, path, direct_head)
          segments = path.to_s.split(".")
          segments.shift if direct_head && segments.first == direct_head
          segments.reduce(materialized) do |held, segment|
            next nil unless held.is_a?(Hash)

            # `key?` decides which spelling answers, never `||` — a
            # genuinely-held `false` must not fall through to the
            # other spelling (usually absent) and read as `nil`.
            sym = segment.to_sym
            held.key?(sym) ? held[sym] : held[segment]
          end
        end

        # Refuses a `has_many` reference offered as anything but an Array, and freezes it
        # through.
        #
        # @param attribute [Bluebook::Attribute] the `has_many` reference attribute, named in
        #   the refusal
        # @param value [Object] the offered value
        # @return [Array] a deep-frozen copy of `value`
        # @raise [Runtime::TypeMismatch] if `value` is not an Array
        def reference_list(attribute, value)
          unless value.is_a?(Array)
            raise TypeMismatch,
                  "#{attribute.name} is a has_many relationship — pass a list of identities"
          end

          Freezer.deep(value.dup)
        end

        # Reshapes an offered value into the plain Hash of fields a value object is built from.
        #
        # @param value_object [Bluebook::ValueObject] the target type; its sole attribute
        #   auto-wraps a bare scalar
        # @param name [String, Symbol] the attribute or mutation target name, quoted in a
        #   refusal
        # @param value [Hash, Runtime::Value, Object] the offered value: a Hash, an existing
        #   `Runtime::Value`, or a bare scalar for a single-field type
        # @return [Hash] `value`'s own fields, Symbol-keyed and not yet defaulted or validated
        # @raise [Runtime::TypeMismatch] if `value` is a bare scalar and `value_object`
        #   declares more than one field
        def fields_for(value_object, name, value)
          return value.transform_keys(&:to_sym) if value.is_a?(Hash)
          # Mutations may legitimately carry a value object into a differently
          # named value-object slot with the same declared fields (for example,
          # PositiveMoney into an Account's Money balance).  Rebuild the target
          # type from its state; callers at the public boundary still have to
          # supply an object rather than a scalar.
          return value.to_h if value.is_a?(self)

          # Vendored addition, not (yet) upstream hecks (migration
          # plan task 5): a bare scalar auto-wraps into a single-field
          # value object's sole attribute -- the same shape
          # #from_identifier already establishes for identity coercion
          # (`build(value_object, { fields.first.name => identifier }) if
          # fields.size == 1`), made consistent here for mutation
          # coercion too. Real, corpus-wide gap: a synthesised single-
          # field wrapper (Part 3a's bare-primitive auto-synthesis, the
          # norm for a VO-typed aggregate field) is exactly the shape
          # #rewrap_arithmetic_result hands back a raw scalar result to
          # -- without this, every phantom-field increment/multiply on a
          # single-field-wrapped attribute refused with "pass its fields
          # as an object, not <scalar>" the instant it tried to re-wrap
          # its own correctly-computed result. Multi-field VOs still
          # refuse below, unchanged -- only the genuinely unambiguous
          # single-field case auto-wraps, matching from_identifier's own
          # precedent exactly.
          return { value_object.attributes.first.name => value } if value_object.attributes.size == 1

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "value_object_shape",
                                           name: name, type: value_object.hecks_name,
                                           offered: Rendering.describe(value))
        end

        # `build`'s own recursive twin of `for_attribute`'s single-level
        # normalization — a value object's own composite-typed fields
        # (`Pizza.price_cents`, a `Price`) never otherwise pass back
        # through `fields_for`, so a bare scalar or partial Hash for one
        # of those sails past the outer VO's own shape check (`Pizza`
        # itself has two fields, so nothing unwraps there) and lands
        # stored one field down exactly as handed in — found live: once
        # the fuzzer actually generated the bare-scalar shape
        # `fields_for` has accepted at the top level since 86727afd, a
        # nested `Price` stored as a raw Integer broke every later
        # dotted-path read (`pizza.price_cents.cents`) expecting one
        # more level of Hash.
        #
        # Stays a plain Hash, never a nested `Value` — `Value#with`'s own
        # header and `materialize_unwrapped`'s comment already depend on
        # a value-object-typed field of another value object staying a
        # plain Hash once stored, and this does not change that; it only
        # makes sure that Hash has the shape its own type declares.
        # `aggregate` is optional on `build` — a nested type can only be
        # resolved through `aggregate.value_object(name)`, so a caller with
        # no aggregate in reach (`Value#with`, always re-setting an
        # already-scalar arithmetic field) simply skips this normalization.
        # Recurses into each nested field's own validation too, not only its
        # shape — found live alongside the shape bug this method's header
        # already describes: a nested `Price`/`Size` (a value-object-typed
        # field of another value object, e.g. `Pizza.price_cents`,
        # `Pizza.size`) had its Hash shape normalized here but never ran
        # `validate!` — `build`, below, only ever validated the outer value
        # object's own direct fields, so a negative `price_cents.cents` or an
        # out-of-`one_of` `size.value` sailed through a `Pizza`-typed command
        # argument untouched, while the exact same nested type declared as a
        # direct, top-level command attribute (`SafeDepositBox.Rent`'s own
        # `attribute :size, Size`) was already checked correctly. `apply_
        # defaults` runs first, same as the outer value object gets in
        # `build`, so a nested field's own default is filled in before its
        # own invariants read it.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity, nil] the construct to
        #   resolve a nested field's own value-object type against; nil (or anything not
        #   responding to `value_object`) skips normalization entirely
        # @param value_object [Bluebook::ValueObject] the type `fields` is being built as
        # @param fields [Hash{Symbol => Object}] the fields being normalized, mutated in place
        #   and also returned
        # @return [Hash{Symbol => Object}] `fields`, with each nested value-object-typed or
        #   list field reshaped, defaulted and validated
        # @raise [Runtime::TypeMismatch] if a nested field's shape does not satisfy its own
        #   declared type
        # @raise [Runtime::InvariantViolation] if a nested field violates its own type's
        #   invariants or closed set
        def normalize_composite_fields(aggregate, value_object, fields)
          return fields unless aggregate.respond_to?(:value_object)

          value_object.attributes.each do |attribute|
            next unless fields.key?(attribute.name)

            # A list member read back from the store hydrates like a top-level
            # list — `list_of(Entity)` elements get their fields coerced,
            # `list_of(ValueObject)` elements become Values — so a value object
            # holding a list loads into the same shape the live dispatch that
            # wrote it held. Found by PR A3 (every adapter through the state
            # codec): chess-style `sets :positions, append: { pieces:
            # state(:pieces) }` snapshots read back from Heki/Sqlite/Postgres
            # (and now Memory's codec copy) with raw element hashes, so a
            # `given` comparing a snapshot piece's `id` Value to a live one
            # never matched after a restart. Load door only: an input list
            # member is left exactly as before, refusals unchanged.
            if attribute.list?
              fields[attribute.name] = for_attribute(aggregate, attribute, fields[attribute.name]) if trusting_stored_state?
              next
            end

            raw = fields[attribute.name]
            next if raw.nil? || raw.is_a?(self)

            nested = value_object_for(aggregate, attribute.type)
            next unless nested

            nested_fields = apply_defaults(nested, fields_for(nested, attribute.name, raw))
            nested_fields = normalize_composite_fields(aggregate, nested, nested_fields)
            validate!(nested, nested_fields)
            fields[attribute.name] = nested_fields
          end

          fields
        end

        # Fills in each declared field's own default, for any field `fields` does not already hold.
        #
        # @param value_object [Bluebook::ValueObject] the type whose declared defaults are read
        # @param fields [Hash{Symbol => Object}] the offered fields, mutated in place and
        #   also returned
        # @return [Hash{Symbol => Object}] `fields`, with each absent field that has a
        #   declared, non-nil default filled in
        def apply_defaults(value_object, fields)
          value_object.attributes.each_with_object(fields) do |attribute, completed|
            completed[attribute.name] = attribute.default unless completed.key?(attribute.name) || attribute.default.nil?
          end
        end

        # Refuses `fields` unless they satisfy the value object's declared shape and invariants.
        #
        # The full door a value object's own fields pass through — shared by
        # `build` (the outer value object) and `normalize_composite_fields`
        # (every nested one), so a nested `Price`/`Size` is refused exactly
        # the same way, with exactly the same wording, as the identical type
        # declared directly on a command.
        #
        # @param value_object [Bluebook::ValueObject] the type `fields` is checked against
        # @param fields [Hash{Symbol => Object}] the already-normalized, already-defaulted
        #   fields
        # @return [void]
        # @raise [Runtime::TypeMismatch] if `fields` holds an undeclared key, a required
        #   field is nil, a numeric or String/boolean field has the wrong Ruby class, a
        #   number is out of the signed 64-bit range or non-finite, or a `pattern:` does not
        #   match
        # @raise [Runtime::InvariantViolation] if `fields` violates one of the type's own
        #   `invariant` rules
        def validate!(value_object, fields)
          # C6.3 (docs/semantics/bluebook-semantics.md) — a value object is
          # validated on construction from input only; state read back from
          # the store is trusted as it was written, so tightening an
          # invariant never makes an old record unreadable (migration is
          # the era system's job). `hydrate` — the one load door — sets
          # the flag; every input door leaves it unset.
          return if trusting_stored_state?

          check_unknown_fields(value_object, fields)
          check_required_fields(value_object, fields)
          admit_member(value_object, fields)
          check_admitted(value_object, fields)
          check_numeric_fields(value_object, fields)
          check_scalar_shapes(value_object, fields)
          check_patterns(value_object, fields)
          value_object.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call_rule(invariant, fields)

            raise InvariantViolation,
                  RefusalWording.render_site("InvariantViolation", "value_object_invariant",
                                             name: value_object.hecks_name, description: invariant.description,
                                             offered: canonical_fields(fields))
          end
        end

        # Builds a validated `Runtime::Value` of the given type: defaults filled in, nested
        # composite fields normalized, and the whole shape checked.
        #
        # @param value_object [Bluebook::ValueObject] the type to build
        # @param fields [Hash] the offered fields, keyed by name (String or Symbol)
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity, nil] the construct to
        #   resolve a nested field's own value-object type against; nil skips nested
        #   normalization (see `normalize_composite_fields`)
        # @return [Runtime::Value] the built, frozen value object
        # @raise [Runtime::TypeMismatch] if `fields` does not satisfy the type's declared
        #   shape, at any nesting depth
        # @raise [Runtime::InvariantViolation] if `fields` violates the type's own
        #   invariants or closed set, at any nesting depth
        def build(value_object, fields, aggregate = nil)
          fields = apply_defaults(value_object, fields.transform_keys(&:to_sym))
          fields = normalize_composite_fields(aggregate, value_object, fields)
          validate!(value_object, fields)
          new(value_object, fields)
        end

        # State arrives decoded or not at all (Phase 2, Track A, PR A4).
        # Every persistence adapter reads through `Ports::Persistence::
        # StateCodec.decode` (A3), which symbolizes every top-level key, and
        # the runtime's own callers (entity elements, the remote dispatcher's
        # `symbolize_names:` parse, Era's audit) build symbol-keyed state
        # themselves. A String key here is an adapter or caller that skipped
        # the codec, so it is refused by name rather than silently respelled
        # with `to_sym` — a String key surviving to this point is exactly
        # what a silent respelling would hide. Always on, because it costs
        # one `is_a?` per key, the same as the `to_sym` it stands in for.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct whose
        #   declared attributes each key is coerced against
        # @param state [Hash] the stored state to hydrate; every key must already be a Symbol
        # @return [Hash{Symbol => Object}] `state` with each declared attribute's value
        #   coerced through `for_attribute`; an undeclared key's value passes through unchanged
        # @raise [Runtime::WiringError] if any key of `state` is not a Symbol
        def hydrate(aggregate, state)
          undecoded = state.keys.grep_v(Symbol)
          unless undecoded.empty?
            raise WiringError,
                  "#{aggregate.name} state reached hydration with non-Symbol keys #{undecoded.inspect} — " \
                  "decode stored state through Hecks::Ports::Persistence::StateCodec.decode first"
          end

          trusting_stored_state do
            state.each_with_object({}) do |(key, value), hydrated|
              attribute = aggregate.attribute(key)
              hydrated[key] = attribute ? for_attribute(aggregate, attribute, value) : value
            end
          end
        end

        TRUSTED_LOAD_KEY = :hecks_trusting_stored_state

        # Runs the block with `trusting_stored_state?` true on this thread, so `validate!` and
        # its callers skip checks that only matter for fresh input (C6.3).
        #
        # `Thread.current`-backed, saved/restored around the call — the same idiom
        # `Runtime::Caller` and `Dispatcher#reenter`'s reaction depth use for
        # per-thread ambient state, so a load on one thread never leaks the
        # flag into another thread's concurrent dispatch.
        #
        # @yield the block to run with the flag set
        # @return [Object] the block's own return value
        def trusting_stored_state
          previous = Thread.current[TRUSTED_LOAD_KEY]
          Thread.current[TRUSTED_LOAD_KEY] = true
          yield
        ensure
          Thread.current[TRUSTED_LOAD_KEY] = previous
        end

        # Answers whether the calling thread is inside a `trusting_stored_state` block.
        #
        # @return [Boolean] true only on the thread, and only for the duration, that
        #   `trusting_stored_state` wraps
        def trusting_stored_state? = Thread.current[TRUSTED_LOAD_KEY] == true

        # QualityControl BUG#125 — the one narrow door `check_scalar_shapes`
        # keeps open, now that a non-string scalar is otherwise refused for a
        # String-typed field. `MetaValidator::Judge#send_to` — the single
        # choke point every one of the language's own self-hosted dispatches
        # goes through while walking a bluebook's declarations into the
        # "Bluebook" meta-domain — wraps itself in this, and nothing else
        # does. `Judge#appends`' generic `POSITION` handling
        # (judge.rb#appends) keys purely off a field being named "position",
        # the convention every other append list actually uses it for
        # (ValueObject::Member, ProcessManager::Handler, ... — all really
        # `Position`/Integer-typed); `Normalise`'s own `NormalisationRule`
        # happens to also name its own domain field "position"
        # (bluebook.bluebook), but declares it `RuleText` (String) — so the
        # same walk-index substitution (`Judge#v(index)`) hands it a raw
        # Integer too, on every domain's very first boot (the language
        # self-judges its own grammar via `MetaValidator.fresh_runtime`'s
        # fixpoint). Confirmed (QualityControl BUG#125 investigation): the
        # resulting value is never read back — `normalisations` is an
        # `ELSEWHERE`/`derived` field spliced straight from
        # `Expression::CanonicalForm.table` (assembly/contracts.rb), so the
        # judged record holding the Integer is discarded whole — this is a
        # walk-index/domain-field name collision inside `Judge#appends`, not
        # a genuine semantic need for `position` to arrive numeric. Fixing
        # that collision at its own root is a separate, larger change to
        # self-hosted bootstrap mechanics that every domain's boot depends
        # on; this flag only ever loosens scalar-shape checking for the
        # meta-grammar's own value objects (RuleText, BluebookName, Position,
        # …) that Judge itself constructs while walking a bluebook's
        # declarations — never for a real domain's own declared value
        # objects (PieceId, Money, …), which Judge never dispatches commands
        # against. `offer` (judge.rb) already converts a `TypeMismatch` here
        # into a recorded refusal rather than letting it propagate, but
        # `MetaValidator.call` raises the instant `refusals` is non-empty
        # (meta_validator.rb) — so, unexempted, this would fail every
        # domain's boot, not just the language's own bootstrap. Composite
        # shapes (Array/Hash) stay refused unconditionally, bootstrap or not
        # — nothing Judge does ever legitimately needs those for a scalar
        # field.
        BOOTSTRAP_KEY = :hecks_judge_bootstrapping

        # Runs the block with `judge_bootstrapping?` true on this thread, loosening
        # `check_scalar_shapes`'s String check for the self-hosted meta-grammar's own bootstrap.
        #
        # `Thread.current`-backed, saved/restored around the call, the same
        # idiom `trusting_stored_state` above uses.
        #
        # @yield the block to run with the flag set
        # @return [Object] the block's own return value
        def judge_bootstrapping
          previous = Thread.current[BOOTSTRAP_KEY]
          Thread.current[BOOTSTRAP_KEY] = true
          yield
        ensure
          Thread.current[BOOTSTRAP_KEY] = previous
        end

        # Answers whether the calling thread is inside a `judge_bootstrapping` block.
        #
        # @return [Boolean] true only on the thread, and only for the duration, that
        #   `judge_bootstrapping` wraps
        def judge_bootstrapping? = Thread.current[BOOTSTRAP_KEY] == true

        # An identity is never guessed from a one-field value object's own
        # opened contents — it names its field explicitly
        # (`identified_by :number`), and that declared path is what reaches
        # the scalar. A declaration that names no field is refused when the
        # bluebook loads, so nothing has to be unwrapped later.
        #
        # `scalar` below is a different job and stays: rendering a value object
        # into a column or a message, where there is no path to consult.

        # A reference is an ID, so anything else is not one.
        #
        # Nothing coerces a reference — `for_attribute` misses on
        # "Reference<Account>", which is no value object's name, and hands the
        # argument straight through. That is why the wrapped form went in
        # unnoticed for as long as it did: there was no place it could be
        # refused, so whatever the first caller wrote became the shape.
        #
        # This is that place. It sits at the payload gate rather than inside
        # coercion because the sentence names the command, and `for_attribute`
        # never learns which command it is serving.
        #
        # Widened past the object shape by BUG#27 (QualityControl ledger,
        # found live on `qa/stress_domains/referral_chain`'s `Member.Join`/
        # `Referral.Issue`). Without this check, a bare Boolean, Array, or
        # `null` would sail through here untouched — nothing but Hash/Value
        # is refused above — then get `.to_s`'d into a lookup key by
        # `CommandRules::References#reference_key` ("true", "false",
        # "[8, 8]") and answer NotFound, or, for `null`, skip the lookup
        # outright (`next if held.nil?`, command_rules/references.rb) and
        # let the command run on to whatever its own `given` happened to
        # say — a shape error misreading as a missing record, or as an
        # unrelated domain refusal. Rust's generated `from_json` requires a JSON
        # string for a required reference field before anything else runs
        # (`JoinArgs.sponsor: expected String`); this closes the same gate
        # at the same DISPATCH_ORDER step Ruby already runs it at
        # (`normalize_args`, `Vocabulary::AggregateDispatchOrder`/
        # `EntityDispatchOrder`), strictly before `resolve_references` ever
        # receives a value to look up — so the two engines now agree on
        # both kind and order, not just kind.
        #
        # `nil` stays legitimate for a `reference_to ..., optional: true`
        # argument (`Improvement.Open`'s own `reference_to Angle, optional:
        # true` — `qa/bluebook/quality_control.bluebook`): the caller
        # genuinely may have nothing to name yet, and `nil_argument`
        # (interpreting.rb) already passes an optional reference's `nil`
        # through untouched. A required reference offered as `null` is a
        # caller leaving a required argument empty in every other sense
        # this runtime already refuses (C3.7) — refusing it here, rather
        # than falling through to `resolve_references`' own nil-skip and
        # then whatever the command's `given` happens to say, is what
        # actually names the empty argument instead of something else.
        #
        # A `has_many` reference's own Array shape is still never refused
        # by its wrapper (`Array(value).find { ... }` only inspects the
        # list's elements) — a reference is never a scalar list-of-lists
        # today, and inventing a rule for a shape the language cannot
        # declare is how decoration gets written. `reference_list` (below)
        # already owns "not an Array at all" for that case.
        #
        # @param command [Bluebook::Command] the command being admitted, named in the refusal
        # @param attribute [Bluebook::Attribute] the reference-typed attribute being checked;
        #   a non-reference attribute is never checked
        # @param value [Object] the offered raw argument value, before coercion
        # @return [void]
        # @raise [Runtime::TypeMismatch] if a required (non-optional) reference is offered as
        #   a Hash or `Runtime::Value`, or anything but a String; a `has_many` reference is
        #   checked only for a Hash/`Runtime::Value` among its offered elements
        def refuse_object_reference(command, attribute, value)
          return unless attribute.reference?

          if attribute.list?
            offered = Array(value).find { |item| item.is_a?(Hash) || item.is_a?(self) }
            return unless offered
          else
            return if value.nil? && attribute.optional?
            return if value.is_a?(String)

            offered = value
          end

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "reference_wrong_shape",
                                           command: command.hecks_name, attribute: attribute.name,
                                           offered: reference_shape_description(offered),
                                           known_by: known_by(attribute))
        end

        # "an object" for the Hash/Value shape — the original wording this
        # method always gave, pinned byte for byte by
        # `spec/runtime/reference_shape_spec.rb`, kept unchanged by BUG#27's
        # widening. `Rendering.describe` for everything else: `true`,
        # `false`, `nil`, `[8, 8]` — the same rendering every other
        # TypeMismatch in this file already uses for "here is what you
        # actually sent."
        #
        # @param value [Object] the offered value refused by `refuse_object_reference`
        # @return [String] `"an object"` for a Hash or `Runtime::Value`; otherwise
        #   `Rendering.describe(value)`
        def reference_shape_description(value)
          return "an object" if value.is_a?(Hash) || value.is_a?(self)

          Rendering.describe(value)
        end

        # "(Account is known by number)" — what to send instead. No article, on
        # purpose: "an Account" and "a Customer" differ by the target's first
        # letter, and a refusal pinned byte-for-byte should not hinge on an
        # article-choosing rule. Silent when the target is another chapter's,
        # where this runtime cannot see what it is known by.
        #
        # Every head, because a caller has to pass every one. This read
        # `identified_by`, which is the single head and is nil the moment an
        # identity has two parts — so a composite target fell through the guard
        # and the refusal went silent exactly where it had the most to say. A
        # single-path target reads as it always did.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute being refused
        # @return [String] `" (Target is known by head1, head2)"`, ready to append to a
        #   refusal message; `""` when the target cannot be resolved (another chapter's
        #   aggregate) or declares no identity heads
        def known_by(attribute)
          heads = Array(attribute.type.resolve&.identity_heads)
          return "" if heads.empty?

          " (#{attribute.type.target_name} is known by #{heads.join(', ')})"
        end

        # Renders a value object into a bare scalar, for a column or a message where there is
        # no declared path to consult.
        #
        # @param value [Object] the value to render
        # @return [Object] `value` unchanged when it is not a `Runtime::Value`; otherwise its
        #   sole field's value
        # @raise [Runtime::TypeMismatch] if `value` is a `Runtime::Value` with more than one field
        def scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          return fields.values.first if fields.size == 1

          raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "multi_field_scalar", type: value.type_name)
        end

        # Wraps a record's own derived identity string back into its declared identity field's
        # value-object type.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct that declares
        #   `attribute`
        # @param attribute [Bluebook::Attribute] the identity attribute; a bare (non-VO) one
        #   is never wrapped
        # @param identifier [String] the record's own derived identity, as `Identity.of`/
        #   `Identity.from` build it
        # @return [Object] `identifier` unchanged when the attribute's type names no value
        #   object; otherwise a single-field `Runtime::Value` of that type, coerced from
        #   `identifier`
        # @raise [Runtime::TypeMismatch] if the attribute's value object declares more than
        #   one field
        def from_identifier(aggregate, attribute, identifier)
          value_object = value_object_for(aggregate, attribute.type)
          return identifier unless value_object

          fields = value_object.attributes
          if fields.size == 1
            field = fields.first
            return build(value_object, { field.name => coerce_identifier(field, identifier) })
          end

          raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "composite_identity", type: value_object.hecks_name)
        end

        # Vendored fix, not (yet) upstream hecks (migration plan
        # task 9): `identifier` here is always the derived identity
        # string -- `Identity.of`/`Identity.from` intentionally return
        # one (correct for naming a repository key), and
        # `Runtime::Instance#materialize_identity!` calls `from_identifier`
        # with exactly that string on every fresh hydration -- but when
        # the identity field's own declared type is Integer/Float (not
        # the overwhelmingly common String), seeding it straight from
        # that string round-trips a correctly-derived identity back in
        # as the wrong Ruby type -- and #build's own
        # `check_numeric_fields` (added specifically to catch a genuine
        # caller mismatch) then refused the runtime's own internal
        # identity seed instead, on every dispatch, valid input or not.
        #
        # Reuses this same file's own `NUMERIC` table (declared-type ->
        # expected-Ruby-class, already read by `check_numeric_fields`)
        # to decide which declared types need converting, and
        # Kernel#Integer/#Float to do the converting. A genuinely
        # malformed identifier (should never happen, since an identity
        # is always derived from a correctly-typed field in the first
        # place, but this stays defensive rather than assume it) passes
        # back unconverted, and `check_numeric_fields` refuses it
        # exactly as it always has -- preserving its real job of
        # catching a genuine caller mismatch, not just this migration's
        # own runtime-internal one.
        private def coerce_identifier(field, identifier)
          return identifier unless identifier.is_a?(String) && NUMERIC.key?(field.type.to_s)

          case field.type.to_s
          when "Integer" then Integer(identifier)
          when "Float"   then Float(identifier)
          else identifier
          end
        rescue ArgumentError
          identifier
        end

        # Renders a value object's fields as JSON, sorted by field name, for a refusal message.
        #
        # @param fields [Hash{Symbol => Object}] the fields to render
        # @return [String] the fields as a JSON object, keys in alphabetical order
        def canonical_fields(fields)
          JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
        end

        # A field declared Integer or Float must arrive as one.
        #
        # Without this a String sails into a numeric field and the failure surfaces
        # later, inside a predicate, as `positive? expects a number, got "three"` —
        # an EvaluationError, which is not a domain refusal. So the runtime broke
        # where the domain should have said no, and the run contract recorded the
        # crash beside genuine refusals as though the domain had judged it.
        #
        # C3.8 — the boundary check for an attribute whose type is a bare
        # primitive rather than a value object: `Integer`/`Float` by exact
        # numeric class (`NUMERIC`), `String`/booleans by rejecting only a
        # composite shape (`COMPOSITE_SHAPES`) — not the same as
        # `check_scalar_shapes` holds a value object's own `String` field to
        # any more (QualityControl BUG#125 tightened that one to also refuse
        # a non-string scalar; a bare `String` argument here still admits
        # any other scalar, left exactly as it was — a bare-primitive
        # attribute was never part of BUG#125's own investigation or fix,
        # and whether it needs the same tightening, and against what real
        # Judge dependency if any, is still open); worded by the same
        # template with the owning construct as `type`. The Rust boundary is
        # stricter there too, recorded in the clause.
        private def check_bare_primitive(owner, attribute, value)
          type = attribute.type.to_s
          expected = NUMERIC[type]
          mistyped = if expected
                       !value.is_a?(expected)
                     elsif NON_NUMERIC_SCALARS.include?(type)
                       COMPOSITE_SHAPES.any? { |shape| value.is_a?(shape) }
                     else
                       false
                     end
          if mistyped
            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "numeric_field",
                                             type: owner.hecks_name, field: attribute.name,
                                             expected: type, offered: Rendering.describe(value))
          end

          check_numeric_bounds(owner.hecks_name, attribute.name, value)
        end

        # C3.3/C3.4 — the value model's own bounds, held at every boundary:
        # an Integer must fit in signed 64 bits, a Float must be finite.
        # One check for value-object fields and bare-primitive arguments
        # alike (`check_numeric_fields` and `check_bare_primitive`).
        INT64_RANGE = (-(2**63))..((2**63) - 1)

        private def check_numeric_bounds(type_name, field_name, given)
          if given.is_a?(Integer) && !INT64_RANGE.cover?(given)
            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "integer_range",
                                             type: type_name, field: field_name, offered: Rendering.describe(given))
          end
          return unless given.is_a?(Float) && !given.finite?

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "non_finite_field",
                                           type: type_name, field: field_name, offered: Rendering.describe(given))
        end

        # QualityControl BUG#41 — a value object refuses a key it does not
        # declare, the same way a command's own payload does
        # (`CommandInterpreter::ArgumentGate#refuse_unknown_arguments`,
        # argument_gate.rb) — reusing that method's exact refusal wording
        # (`UnknownArgument unknown_args`, refusal_wording.rb:
        # "{command} does not declare {unknown} — it takes {declared}")
        # rather than inventing a new template, because every generated
        # Rust value-object `from_json` already renders this refusal
        # through that identical site: `rust/project/json_codec.rb`'s
        # `emit_unknown_argument_check` (mirrored byte-for-byte in
        # `rust/codegen/src/json_codec.rs`) emits `v.unknown_keys(&[...])`
        # and the same "{name} does not declare {unknown} — it takes
        # {declared}" format string for every value object's own
        # `from_json` — `GameLabel::from_json`
        # (rust/src/generated/chess/game.rs) is simply the first case
        # this gap was reproduced against.
        #
        # Ruby never had an equivalent check anywhere in this `validate!`
        # door before now — `fields[attribute.name]` reads only the
        # declared attributes, so any other key a caller's Hash carried
        # was silently ignored. `fields` here only ever holds what a
        # caller (or `for_attribute`'s own recursive coercion) offered
        # for this value object — built by `fields_for`'s plain
        # key-symbolizing (never a Hash the runtime pads with bookkeeping
        # keys of its own; confirmed by reading every call site that
        # reaches `validate!`) — so there is nothing legitimate here to
        # exempt.
        #
        # Checked first, before `check_required_fields` and everything
        # after it — matching Rust's own `from_json`, which checks
        # `unknown_keys` before reading a single declared field. So a
        # Hash offering both an unrecognized key and a missing required
        # one (BUG#41's own second demonstration case: `label: {extra:
        # "bogus"}` — unknown and missing `value`) refuses the same
        # UnknownArgument on both engines, not two different refusal
        # kinds for one malformed call.
        private def check_unknown_fields(value_object, fields)
          known   = value_object.attributes.map { |attribute| attribute.name.to_sym }
          unknown = (fields.keys.map(&:to_sym) - known).sort
          return if unknown.empty?

          declared = value_object.attributes.map(&:name)
          raise UnknownArgument,
                RefusalWording.render_site("UnknownArgument", "unknown_args",
                                           command: value_object.hecks_name, unknown: unknown,
                                           declared: declared)
        end

        # C3.7 — a value object is a typed field product: every non-optional
        # field arrives, or construction refuses. A missing field and a null
        # one are the same absence (`fields[name]` reads nil for both), worded
        # as the type mismatch it is — "{type}.{field} expects {expected}, got
        # nil" — the identical string the Rust side's generated `from_json`
        # gives the same input, so the corpus can pin it on both. Checked
        # first among the field-content checks (after `check_unknown_fields`'s
        # own structural gate above, BUG#41): without this check, an invariant
        # reading a field that never arrived would answer "invariant violated"
        # (or nothing at all — `ToppingName`'s `{value: null}` would be
        # accepted and stored). A `default:` has already been filled in by
        # `apply_defaults`; a list field's absence is an empty list, never a
        # refusal.
        private def check_required_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            next if attribute.optional? || attribute.list?
            next unless fields[attribute.name].nil?

            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "numeric_field",
                                             type: value_object.hecks_name, field: attribute.name,
                                             expected: attribute.type, offered: "nil")
          end
        end

        # Checked before invariants, because an invariant reading a mistyped field
        # is exactly the shape of raw Ruby error this check turns into a refusal.
        NUMERIC = { "Integer" => Integer, "Float" => Numeric }.freeze
        private def check_numeric_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            expected = NUMERIC[attribute.type.to_s]
            next unless expected

            given = fields[attribute.name]
            next if given.nil?

            unless given.is_a?(expected)
              raise TypeMismatch,
                    RefusalWording.render_site("TypeMismatch", "numeric_field",
                                               type: value_object.hecks_name, field: attribute.name,
                                               expected: attribute.type, offered: Rendering.describe(given))
            end

            # PRD 05 (numeric-boundary-coverage) — `given.is_a?(expected)`
            # alone waves a NaN or an Infinity straight through: both are
            # real `Float`s, so `is_a?(Numeric)`/`is_a?(Float)` is true for
            # either. Never exercised before this, because
            # `ValueGenerator::FLOAT_EDGE_CASES` had no non-finite value in
            # it — the fuzzer could not have found this on its own until
            # the table was widened alongside this fix. Left unchecked, a
            # non-finite Float reaches `CommandRules::Arithmetic#clamp`
            # (`current.clamp(min, max)` — `ArgumentError: comparison of
            # Float with X failed`, a genuine Ruby-level crash, not a
            # domain refusal, exactly the same failure mode this method's
            # own header describes for a mistyped field) or all the way to
            # storage, where `JSON.generate`/`#to_json` raises
            # `JSON::GeneratorError: NaN/Infinity not allowed in JSON` the
            # moment anything tries to persist or replay it — again a raw
            # crash, not a refusal. `-0.0` is deliberately not refused
            # here: it is finite, round-trips through JSON as `-0.0`
            # cleanly (confirmed empirically), and is a legitimate,
            # meaningful float value (a signed zero), not a corruption
            # risk — only NaN and +/-Infinity are.
            check_numeric_bounds(value_object.hecks_name, attribute.name, given)
          end
        end

        # A field declared `String` (or a boolean) must not arrive as a
        # composite — an Array or a Hash (or a nested Value) standing in for
        # what has to be a leaf scalar. A `String` field, further, must not
        # arrive as any other non-composite scalar either (Integer, Float,
        # true/false) — QualityControl BUG#125, matching Rust's generated
        # `from_json`, which requires a JSON string node for a String-typed
        # field unconditionally and refuses anything else, including a JSON
        # number or boolean. Found live: `Chess::Piece.Capture`'s `PieceId`,
        # String-typed, offered a bignum `id` — without this check, Ruby
        # lets it pass and fails later on an unrelated field, where Rust
        # refuses on `id` itself, immediately. Except inside
        # `judge_bootstrapping?` (above), the one caller genuinely relying
        # on the looser reading; see that flag's own comment for why.
        #
        # `TrueClass`/`FalseClass` stay laxer than `check_numeric_fields`
        # above: for those two, this still only enforces that the shape
        # isn't a collection, not the exact Ruby class — narrower than the
        # `String` case above because BUG#125 investigated and fixed String
        # specifically; a boolean field's own scalar-shape tolerance is a
        # separate, uninvestigated question left exactly as it was. No
        # scalar field, of any declared type, can ever legitimately be
        # handed an Array or a Hash — that shape is always wrong, and always
        # was: `InvalidValueGenerator#array_for_scalar`'s own corruption is
        # deliberately built to be refused (see that file's header), and
        # until this check existed it sailed straight through for a
        # String/boolean field the way it never could for an Integer/Float
        # one (`check_numeric_fields` above already catches an Array offered
        # for those). Found live via bin/fuzz, seed 17 on the fixtures
        # domain : an Array standing in for a single-field identity's
        # declared `String`, `.to_s`'d into a record id downstream.
        COMPOSITE_SHAPES = [Array, ::Hash].freeze
        NON_NUMERIC_SCALARS = %w[String TrueClass FalseClass].freeze
        private def check_scalar_shapes(value_object, fields)
          value_object.attributes.each do |attribute|
            type = attribute.type.to_s
            next unless NON_NUMERIC_SCALARS.include?(type)

            given = fields[attribute.name]
            next if given.nil?

            composite = COMPOSITE_SHAPES.any? { |shape| given.is_a?(shape) }
            non_string_scalar = type == "String" && !composite && !given.is_a?(String) && !judge_bootstrapping?
            next unless composite || non_string_scalar

            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "numeric_field",
                                             type: value_object.hecks_name, field: attribute.name,
                                             expected: attribute.type, offered: Rendering.describe(given))
          end
        end

        # A field declared with a pattern must match it.
        #
        # Beside check_numeric_fields and for the same reason : a value that does
        # not look like what it claims to be is the domain saying no, and it should
        # say so here rather than let the wrong shape travel on and surface as a
        # broken predicate later.
        #
        # Which regexes may be written at all is PatternSubset's job, enforced when
        # the bluebook is declared — so by the time a value arrives here the pattern
        # is already a vetted, unambiguous one, and this is a plain match.
        private def check_patterns(value_object, fields)
          value_object.attributes.each do |attribute|
            pattern = attribute.pattern
            next unless pattern

            given = fields[attribute.name]
            next if given.nil?
            next if given.is_a?(String) && Regexp.new(pattern).match?(given)

            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "pattern_mismatch",
                                             type: value_object.hecks_name, field: attribute.name,
                                             pattern: pattern, offered: Rendering.describe(given))
          end
        end
      end
    end
  end
end
