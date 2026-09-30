require_relative "../../bluebook/expression/evaluator"
require_relative "../../naming"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "invariant_violation"

module Hecks
  module Runtime
    class Value
      # Class-side coercion engine for Value, extended in so its methods read
      # as `Value.for`, `Value.build`, and so on.
      module Coercion
        # The complete set of attribute value shapes. Mirrored by hand into a
        # generated Rust enum (hecks project_kernel_capabilities) — adding a shape
        # here without a matching Rust file leaves the kernel unaware of it.
        SHAPES = %i[scalar list optional composite].freeze

        # Coerces `value` for one of `aggregate`'s declared attributes, by name.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct to look
        #   up `name` on
        # @param name [String, Symbol] the declared attribute name
        # @param value [Object] the raw value to coerce
        # @return [Runtime::Value, Object, nil] the coerced value, or `value`
        #   unchanged if `aggregate` declares no such attribute
        # @raise [Runtime::TypeMismatch] if `value` cannot be coerced to the declared type
        # @raise [Runtime::UnknownArgument] if `value` is a Hash naming an undeclared field
        # @raise [Runtime::InvariantViolation] if a coerced value object breaks an invariant
        def for(aggregate, name, value)
          attribute = aggregate.attribute(name)
          return value unless attribute

          for_attribute(aggregate, attribute, value)
        end

        # Coerces `value` for a single, already-resolved `attribute`, branching on
        # its declared shape (list, reference, composite, or bare scalar).
        #
        # `boundary: false` is the query door, where a declared type documents the
        # argument for callers/generators rather than naming a shape to enforce.
        # `argument: true` is the command/entity/port dispatch door, where a nil for
        # a required attribute is a left-empty argument (C3.7), not ordinary state nil.
        #
        # @raise [Runtime::TypeMismatch] if `value` cannot be coerced, or a required
        #   reference/attribute is a wrong-shaped value
        # @raise [Runtime::UnknownArgument] if `value` is a Hash naming an undeclared field
        # @raise [Runtime::InvariantViolation] if a coerced value object breaks an invariant
        def for_attribute(aggregate, attribute, value, boundary: true, argument: false)
          return nil_or_missing(aggregate, attribute, value, argument) if attribute.nil? || value.nil?
          return reference_list(attribute, value) if attribute.list? && attribute.reference?
          return reference_identity(attribute, value) if attribute.reference?
          return hydrate_entity_list(aggregate, attribute, value) if attribute.list? # :list
          return value unless aggregate.respond_to?(:value_object)

          # `admits:` is checked here, where the attribute is known — `build` only
          # sees the value object. Checked after coercion: a scalar arrives wrapped
          # in its type's own holder, and checking the raw payload would be wrong.
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

        # A required argument's nil is refused (C3.7); state assembly, hydration
        # and query nils pass through unchanged. Lists/references keep their own
        # nil passthrough regardless of `argument`.
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

        # A bare primitive is boundary-checked too (C3.8) — wrong-typed input
        # refuses here as a TypeMismatch, never later as a broken predicate.
        # Its `admits:` set is still checked, exactly as a value object's is.
        private def bare_primitive(aggregate, attribute, value, boundary)
          check_bare_primitive(aggregate, attribute, value) if boundary
          admit_declared_set(aggregate, attribute, value)
          value
        end

        # Resolves the value-object class `type` names: `aggregate`'s own
        # declarations first, then its chapter's other aggregates if they agree.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct to search first
        # @param type [String, Symbol, #to_s] the declared type name to resolve
        # @return [Class, nil] the `Bluebook::ValueObject` subclass `type` names, or nil
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

        # Coerces a reference-typed attribute's offered value into the target's own
        # canonical identity string.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute
        # @param value [Object] a bare scalar identity, a `Runtime::Value`, or a Hash
        #   naming the target's own identity fields
        # @return [String, Object] the joined identity String, or `value` unchanged
        #   when it cannot be resolved
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

        # Unwraps `value` to a bare scalar when `paths` names exactly one identity
        # field and `value` is itself a single-attribute value object — the only
        # case where unwrapping cannot be ambiguous.
        #
        # @param value [Object] the offered reference value to unwrap
        # @param paths [Array<String>] the target's own declared identity paths
        # @return [Object, nil] the unwrapped scalar, or nil if it does not apply
        def sole_scalar_identity(value, paths)
          return nil unless value.is_a?(self) && paths.one?
          return nil unless value.value_object.sole_attribute

          materialize_unwrapped(value)
        end

        # Whether `value` is itself the target's own single identity value object.
        #
        # @param value [Object] the offered reference value to check
        # @param target [Bluebook::Aggregate] the reference's own resolved target
        # @return [String, nil] the target's identity head name, or nil
        def direct_identity_head(value, target)
          return nil unless value.is_a?(self) && target.identity_heads.one?

          head = target.identity_heads.first
          target.attribute(head)&.type.to_s == value.type_name ? head.to_s : nil
        end

        # One identity path's own value out of the materialized hash, stripping a
        # leading segment already covered by `direct_identity_head`.
        #
        # @param materialized [Hash, Object] the offered reference value as a Hash
        # @param path [String, Symbol] one dotted identity path to dig
        # @param direct_head [String, nil] leading segment to strip, if present
        # @return [Object, nil] the value found by walking `path`, or nil if missing
        def identity_part(materialized, path, direct_head)
          segments = path.to_s.split(".")
          segments.shift if direct_head && segments.first == direct_head
          segments.reduce(materialized) do |held, segment|
            next nil unless held.is_a?(Hash)

            # `key?` decides which spelling answers — a genuinely-held `false`
            # must not fall through to the other spelling and read as `nil`.
            sym = segment.to_sym
            held.key?(sym) ? held[sym] : held[segment]
          end
        end

        # Coerces a `has_many` reference-typed attribute's offered value.
        #
        # @param attribute [Bluebook::Attribute] the `has_many` reference attribute
        # @param value [Object] the offered value; must be an Array
        # @return [Array] `value`, deep-frozen and duped
        # @raise [Runtime::TypeMismatch] if `value` is not an Array
        def reference_list(attribute, value)
          unless value.is_a?(Array)
            raise TypeMismatch,
                  "#{attribute.name} is a has_many relationship — pass a list of identities"
          end

          Freezer.deep(value.dup)
        end

        # Normalizes an offered value into `value_object`'s own field Hash, before
        # defaults, nested normalization and validation run.
        #
        # @param value_object [Class] the target `Bluebook::ValueObject` subclass
        # @param name [String, Symbol] the attribute or argument name, quoted in a refusal
        # @param value [Hash, Runtime::Value, Object] a Hash of fields, an already-built
        #   `Value`, or a bare scalar for a single-field value object
        # @return [Hash{Symbol => Object}] the offered fields, keyed by attribute name
        # @raise [Runtime::TypeMismatch] if `value` is a bare scalar and `value_object`
        #   declares more than one field
        def fields_for(value_object, name, value)
          return value.transform_keys(&:to_sym) if value.is_a?(Hash)
          # A same-shaped value object may fill a differently-named slot (e.g.
          # PositiveMoney into an Account's Money balance) — rebuild from its state.
          return value.to_h if value.is_a?(self)

          # A bare scalar auto-wraps into a single-field value object's sole
          # attribute, matching `from_identifier`'s own precedent. Multi-field
          # value objects still refuse below.
          return { value_object.attributes.first.name => value } if value_object.attributes.size == 1

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "value_object_shape",
                                           name: name, type: value_object.hecks_name,
                                           offered: Rendering.describe(value))
        end

        # `build`'s own recursive twin of `for_attribute`, normalizing a value
        # object's own composite-typed fields into their declared shape.
        #
        # Stays a plain Hash, never a nested `Value` — `Value#with` depends on that.
        #
        # @param aggregate [Bluebook::Aggregate, Entity, nil] nested-type lookup scope
        # @param value_object [Class] the value object `fields` belongs to
        # @param fields [Hash{Symbol => Object}] the outer fields, already defaulted
        # @return [Hash{Symbol => Object}] `fields` with composite fields normalized
        # @raise [Runtime::TypeMismatch] if a nested field cannot be coerced
        # @raise [Runtime::UnknownArgument] if a nested field names an undeclared key
        # @raise [Runtime::InvariantViolation] if a nested field breaks its own invariant
        def normalize_composite_fields(aggregate, value_object, fields)
          return fields unless aggregate.respond_to?(:value_object)

          value_object.attributes.each do |attribute|
            next unless fields.key?(attribute.name)

            # A list member hydrates the same as a top-level list, so a value
            # read back from the store matches the shape a live dispatch wrote.
            # Load door only — an input list member is left as offered.
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

        # Fills every declared attribute `fields` lacks with its own `default:`.
        #
        # @param value_object [Class] the `Bluebook::ValueObject` subclass whose
        #   declared defaults are read
        # @param fields [Hash{Symbol => Object}] the offered fields; written in place
        # @return [Hash{Symbol => Object}] `fields`, with defaults filled in
        def apply_defaults(value_object, fields)
          value_object.attributes.each_with_object(fields) do |attribute, completed|
            completed[attribute.name] = attribute.default unless completed.key?(attribute.name) || attribute.default.nil?
          end
        end

        # The full door a value object's own fields pass through — shared by
        # `build` and `normalize_composite_fields`, so a nested field refuses
        # exactly like the same type declared directly on a command.
        #
        # @param value_object [Class] the `Bluebook::ValueObject` subclass to
        #   validate `fields` against
        # @param fields [Hash{Symbol => Object}] already-defaulted, nested-normalized fields
        # @return [void]
        # @raise [Runtime::UnknownArgument] if `fields` names an undeclared key
        # @raise [Runtime::TypeMismatch] if a required field is missing or wrong-shaped
        # @raise [Runtime::InvariantViolation] if `fields` breaks a declared invariant
        def validate!(value_object, fields)
          # C6.3 — a value object validates on construction from input only; state
          # read back from the store is trusted as written, so tightening an
          # invariant never makes an old record unreadable. `hydrate` sets this flag.
          return if trusting_stored_state?

          check_unknown_fields(value_object, fields)
          check_required_fields(value_object, fields)
          admit_member(value_object, fields)
          check_admitted(value_object, fields)
          check_list_shapes(value_object, fields)
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

        # Builds one validated `Value` of `value_object`'s own type: defaults filled,
        # nested fields normalized and validated, then the whole thing checked.
        #
        # @param value_object [Class] the `Bluebook::ValueObject` subclass to build
        # @param fields [Hash{Symbol, String => Object}] the offered field values,
        #   either key spelling
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity, nil] construct a
        #   nested composite field resolves against; nil skips nested normalization
        # @return [Runtime::Value] the built, validated value object
        # @raise [Runtime::UnknownArgument] if a field names an undeclared key
        # @raise [Runtime::TypeMismatch] if a field cannot be coerced to its declared type
        # @raise [Runtime::InvariantViolation] if the built value object breaks an invariant
        def build(value_object, fields, aggregate = nil)
          fields = apply_defaults(value_object, fields.transform_keys(&:to_sym))
          fields = normalize_composite_fields(aggregate, value_object, fields)
          validate!(value_object, fields)
          new(value_object, fields)
        end

        # State arrives decoded or not at all: every persistence adapter symbolizes
        # keys before this point, so a String key here means a caller skipped that
        # step — refused by name rather than silently respelled.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct whose
        #   declared attributes coerce `state`'s own values
        # @param state [Hash{Symbol => Object}] the stored state to hydrate; every
        #   key must already be a Symbol
        # @return [Hash{Symbol => Object}] `state`, coerced through each declared attribute
        # @raise [Runtime::WiringError] if `state` holds any non-Symbol key
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

        # Marks the block as loading trusted, already-validated stored state, so
        # `validate!` skips its own checks for the block's duration.
        #
        # Thread-local, not a plain ivar, so two threads hydrating concurrently
        # never see or clear each other's flag.
        #
        # @yield the code that should see `trusting_stored_state?` true
        # @return [Object] the block's result
        def trusting_stored_state
          previous = Thread.current[TRUSTED_LOAD_KEY]
          Thread.current[TRUSTED_LOAD_KEY] = true
          yield
        ensure
          Thread.current[TRUSTED_LOAD_KEY] = previous
        end

        # Whether the current thread is inside a `trusting_stored_state` block.
        #
        # @return [Boolean] true if on this thread's own call stack
        def trusting_stored_state? = Thread.current[TRUSTED_LOAD_KEY] == true

        # `MetaValidator::Judge#send_to` walks a bluebook's own declarations through
        # the self-hosted "Bluebook" meta-domain, and its generic append handling
        # keys off a field's name ("position") rather than its declared type — so
        # the language's own grammar can hand this a raw Integer for a String-typed
        # meta field on every domain's first boot. This flag loosens
        # `check_scalar_shapes`'s String check only for that one caller; composite
        # shapes (Array/Hash) stay refused unconditionally, bootstrap or not, and no
        # real domain's own declared value objects are affected.
        BOOTSTRAP_KEY = :hecks_judge_bootstrapping

        # Marks the block as `MetaValidator::Judge#send_to`'s self-hosted bootstrap
        # dispatch, so `check_scalar_shapes` loosens its `String` check for the
        # block's duration.
        #
        # Thread-local, not a plain ivar, so two threads bootstrapping concurrently
        # never see or clear each other's flag.
        #
        # @yield the code that should see `judge_bootstrapping?` true
        # @return [Object] the block's result
        def judge_bootstrapping
          previous = Thread.current[BOOTSTRAP_KEY]
          Thread.current[BOOTSTRAP_KEY] = true
          yield
        ensure
          Thread.current[BOOTSTRAP_KEY] = previous
        end

        # Whether the current thread is inside a `judge_bootstrapping` block.
        #
        # @return [Boolean] true if on this thread's own call stack
        def judge_bootstrapping? = Thread.current[BOOTSTRAP_KEY] == true

        # A reference is an ID; refused at the payload gate if it arrives as a
        # Hash or `Runtime::Value` instead. `nil` stays legitimate for an optional
        # reference — a required reference's own `nil` is refused elsewhere (C3.7).
        #
        # @param command [Class] the command `attribute` is declared on, named in a refusal
        # @param attribute [Bluebook::Attribute] the attribute to check; a no-op unless
        #   reference-typed
        # @param value [Object] the offered value
        # @return [void]
        # @raise [Runtime::TypeMismatch] if `value` (or an element, for `has_many`) is a
        #   Hash or `Runtime::Value` rather than a plain identity
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

        # "an object" for the Hash/Value shape; `Rendering.describe` otherwise —
        # the same rendering every other TypeMismatch in this file uses.
        #
        # @param value [Object] the wrongly-shaped offered value to describe
        # @return [String] `"an object"` for a Hash or `Runtime::Value`; otherwise
        #   `Rendering.describe(value)`
        def reference_shape_description(value)
          return "an object" if value.is_a?(Hash) || value.is_a?(self)

          Rendering.describe(value)
        end

        # "(Account is known by number)" — what to send instead. No article, since
        # "an Account" vs "a Customer" would make a pinned refusal hinge on spelling.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute to
        #   describe the target's identity heads for
        # @return [String] `" (Target is known by head1, head2)"`, or `""` if the
        #   target or its identity heads cannot be resolved
        def known_by(attribute)
          heads = Array(attribute.type.resolve&.identity_heads)
          return "" if heads.empty?

          " (#{attribute.type.target_name} is known by #{heads.join(', ')})"
        end

        # Renders a value object into the bare scalar its one field holds — for a
        # column or a message, where there is no path to consult.
        #
        # @param value [Object] the value to render; passed through unless a `Runtime::Value`
        # @return [Object] `value` unchanged, or its one field's own value
        # @raise [Runtime::TypeMismatch] if `value` has more than one field
        def scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          return fields.values.first if fields.size == 1

          raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "multi_field_scalar", type: value.type_name)
        end

        # Coerces a derived identity string back into `attribute`'s own declared type.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] construct
        #   `attribute` is declared on
        # @param attribute [Bluebook::Attribute] the identity attribute to coerce for
        # @param identifier [String, Object] the derived identity
        # @return [Runtime::Value, String, Object] a built value object for a
        #   single-field value-object type; `identifier` unchanged otherwise
        # @raise [Runtime::TypeMismatch] if the type names a multi-field value object
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

        # Converts a derived numeric identity string back before `check_numeric_fields` runs.
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

        # Renders a value object's fields as a canonical JSON string, for an
        # invariant refusal to quote.
        #
        # @param fields [Hash{Symbol, String => Object}] the field values to render
        # @return [String] `fields`, sorted by key name and JSON-encoded
        def canonical_fields(fields)
          JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
        end

        # C3.8 boundary check — refuses a mistyped argument before it breaks a predicate.
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

        # C3.3/C3.4 — value bounds enforced at every boundary: an Integer must fit
        # signed 64 bits, a Float must be finite.
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

        # A value object refuses an undeclared key the same way a command's own
        # payload does, checked before any other field-content check.
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

        # C3.7 — every non-optional, non-list field must arrive (or construction
        # refuses); a `default:` has already been filled in by `apply_defaults`.
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
        # is exactly the thing that would otherwise explode.
        NUMERIC = { "Integer" => Integer, "Float" => Numeric }.freeze
        private def check_numeric_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            expected = NUMERIC[attribute.type.to_s]
            next unless expected

            given = fields[attribute.name]
            next if given.nil?

            offered_items(attribute, given).each do |item|
              unless item.is_a?(expected)
                raise TypeMismatch,
                      RefusalWording.render_site("TypeMismatch", "numeric_field",
                                                 type: value_object.hecks_name, field: attribute.name,
                                                 expected: attribute.type, offered: Rendering.describe(item))
              end

              # `is_a?(expected)` alone waves NaN/Infinity through — both are real
              # Floats. `-0.0` is deliberately left unchecked: finite and legitimate.
              check_numeric_bounds(value_object.hecks_name, attribute.name, item)
            end
          end
        end

        # A `list_of` field holds an Array whatever its element type, so a lone scalar
        # offered for it is refused; nil stays legitimate, as it is for any optional field.
        private def check_list_shapes(value_object, fields)
          value_object.attributes.each do |attribute|
            given = fields[attribute.name]
            next unless attribute.list? && !given.nil? && !given.is_a?(Array)

            raise TypeMismatch, RefusalWording.render_site(
              "TypeMismatch", "numeric_field", type: value_object.hecks_name, field: attribute.name,
              expected: "list_of(#{attribute.type})", offered: Rendering.describe(given)
            )
          end
        end

        # The values a field's element-level checks apply to: each element of a list, or the
        # one value of a scalar field.
        private def offered_items(attribute, given) = attribute.list? && given.is_a?(Array) ? given : [given]

        # A scalar field (String, or a boolean) must not arrive as a composite
        # (Array/Hash) standing in for a leaf value. A String field additionally
        # must not arrive as any other scalar, except inside `judge_bootstrapping?`.
        COMPOSITE_SHAPES = [Array, ::Hash].freeze
        NON_NUMERIC_SCALARS = %w[String TrueClass FalseClass].freeze
        private def check_scalar_shapes(value_object, fields)
          value_object.attributes.each do |attribute|
            type = attribute.type.to_s
            next unless NON_NUMERIC_SCALARS.include?(type)

            given = fields[attribute.name]
            next if given.nil?

            offered_items(attribute, given).each do |item|
              composite = COMPOSITE_SHAPES.any? { |shape| item.is_a?(shape) }
              non_string_scalar = type == "String" && !composite && !item.is_a?(String) && !judge_bootstrapping?
              next unless composite || non_string_scalar

              raise TypeMismatch,
                    RefusalWording.render_site("TypeMismatch", "numeric_field",
                                               type: value_object.hecks_name, field: attribute.name,
                                               expected: attribute.type, offered: Rendering.describe(item))
            end
          end
        end

        # A field declared with a pattern must match it, refused as a TypeMismatch
        # rather than surfacing later as a broken predicate. The pattern itself is
        # already vetted by PatternSubset when the bluebook is declared.
        private def check_patterns(value_object, fields)
          value_object.attributes.each do |attribute|
            pattern = attribute.pattern
            next unless pattern

            given = fields[attribute.name]
            next if given.nil?

            offered_items(attribute, given).each do |item|
              next if item.is_a?(String) && Regexp.new(pattern).match?(item)

              raise TypeMismatch,
                    RefusalWording.render_site("TypeMismatch", "pattern_mismatch",
                                               type: value_object.hecks_name, field: attribute.name,
                                               pattern: pattern, offered: Rendering.describe(item))
            end
          end
        end
      end
    end
  end
end
