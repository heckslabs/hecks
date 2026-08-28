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
        # THE FOUR SHAPES AN ATTRIBUTE'S VALUE CAN TAKE — named here because
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
        # A SECOND RUNTIME'S KERNEL PORTS THIS METHOD BY HAND (rust/src/
        # kernel/attribute_shapes/*.rs — one file per name in this array,
        # generated into a Rust enum by bin/project_kernel_capabilities so
        # every match over it is compiler-checked exhaustive). If a fifth
        # branch is ever added to `for_attribute`, add its name here in the
        # same breath — this list is that port's only source of truth for
        # "which shapes exist," and a shape missing from it is a shape the
        # generated Rust enum, and therefore the kernel, can never learn
        # about no matter how correct the Ruby below is.
        SHAPES = %i[scalar list optional composite].freeze

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
        def for_attribute(aggregate, attribute, value)
          return value if attribute.nil? || value.nil? # :optional
          return reference_list(attribute, value) if attribute.list? && attribute.reference?
          return reference_identity(attribute, value) if attribute.reference?
          return hydrate_entity_list(aggregate, attribute, value) if attribute.list? # :list
          return value unless aggregate.respond_to?(:value_object)

          # THE SET THE ATTRIBUTE NAMES IS CHECKED WHERE THE ATTRIBUTE IS KNOWN.
          # `build` below sees only the value object, never which attribute asked
          # for it, so a command argument's `admits:` has to be read here — this
          # is the door every argument and every head field comes through.
          #
          # AFTER coercion, not before: a scalar arrives wrapped in whatever holder
          # its type names (`{value: "append"}` for an OpName), and checking the
          # raw payload would be checking the envelope.
          coerced = value_object_for(aggregate, attribute.type)
                    .then do |value_object|
                      if value.is_a?(self) && value.type_name == value_object&.hecks_name
                        value
                      elsif value_object
                        build(value_object, fields_for(value_object, attribute.name, value), aggregate)
                      else
                        value
                      end
                    end

          admit_declared_set(aggregate, attribute, coerced)
          coerced
        end

        # Aggregate-local value objects remain authoritative, which permits
        # intentional duplication. An ordinary fact may also name an identity
        # value object declared on another aggregate; that shape is borrowed
        # only when every chapter declaration with the name agrees.
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
        def reference_identity(attribute, value)
          return value unless value.is_a?(self) || value.is_a?(Hash)

          target = attribute.type.resolve
          return value unless target

          materialized = materialize(value)
          paths = target.identity_paths
          return value if paths.empty?

          direct_head = if value.is_a?(self) && target.identity_heads.one?
                          head = target.identity_heads.first
                          target.attribute(head)&.type.to_s == value.type_name ? head.to_s : nil
                        end

          parts = paths.map do |path|
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
          return value if parts.any? { |part| part.nil? || (part.respond_to?(:empty?) && part.empty?) }

          Naming.identity(parts)
        end

        def reference_list(attribute, value)
          unless value.is_a?(Array)
            raise TypeMismatch,
                  "#{attribute.name} is a has_many relationship — pass a list of identities"
          end

          Freezer.deep(value.dup)
        end

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
          # value object's sole attribute -- the SAME shape
          # #from_identifier already establishes for identity coercion
          # (`build(value_object, { fields.first.name => identifier }) if
          # fields.size == 1`), made consistent here for MUTATION
          # coercion too. Real, corpus-wide gap: a synthesised single-
          # field wrapper (Part 3a's bare-primitive auto-synthesis, the
          # norm for a VO-typed aggregate field) is exactly the shape
          # #rewrap_arithmetic_result hands back a raw scalar RESULT to
          # -- without this, every phantom-field increment/multiply on a
          # single-field-wrapped attribute refused with "pass its fields
          # as an object, not <scalar>" the instant it tried to re-wrap
          # its own correctly-computed result. Multi-field VOs still
          # refuse below, unchanged -- only the genuinely unambiguous
          # single-field case auto-wraps, matching from_identifier's own
          # precedent exactly.
          if value_object.attributes.size == 1
            return { value_object.attributes.first.name => value }
          end

          raise TypeMismatch,
                RefusalWording.render("TypeMismatch", "value_object_shape",
                                      name: name, type: value_object.hecks_name,
                                      offered: Rendering.describe(value))
        end

        # `build`'s own recursive twin of `for_attribute`'s single-level
        # normalization — a value object's OWN composite-typed fields
        # (`Pizza.price_cents`, a `Price`) never otherwise pass back
        # through `fields_for`, so a bare scalar or partial Hash for one
        # of THOSE sails past the outer VO's own shape check (`Pizza`
        # itself has two fields, so nothing unwraps there) and lands
        # stored one field down exactly as handed in — found live: once
        # the fuzzer actually generated the bare-scalar shape
        # `fields_for` has accepted at the TOP level since 86727afd, a
        # nested `Price` stored as a raw Integer broke every later
        # dotted-path read (`pizza.price_cents.cents`) expecting one
        # more level of Hash.
        #
        # Stays a plain Hash, never a nested `Value` — `Value#with`'s own
        # header and `materialize_unwrapped`'s comment already depend on
        # a value-object-typed field of ANOTHER value object staying a
        # plain Hash once stored, and this does not change that; it only
        # makes sure that Hash has the shape its own type declares.
        # `aggregate` is the one thing `build` didn't used to need — a
        # nested type can only be resolved through `aggregate.
        # value_object(name)`, so callers with no aggregate in reach
        # (`Value#with`, always re-setting an already-scalar arithmetic
        # field) simply skip this and keep their prior behavior.
        # RECURSES INTO EACH NESTED FIELD'S OWN VALIDATION TOO, not only its
        # shape — found live alongside the shape bug this method's header
        # already describes: a nested `Price`/`Size` (a value-object-typed
        # field of ANOTHER value object, e.g. `Pizza.price_cents`,
        # `Pizza.size`) had its Hash shape normalized here but never ran
        # `validate!` — `build`, below, only ever validated the OUTER value
        # object's own direct fields, so a negative `price_cents.cents` or an
        # out-of-`one_of` `size.value` sailed through a `Pizza`-typed command
        # argument untouched, while the exact same nested type declared as a
        # direct, top-level command attribute (`SafeDepositBox.Rent`'s own
        # `attribute :size, Size`) was already checked correctly. `apply_
        # defaults` runs first, same as the outer value object gets in
        # `build`, so a nested field's own default is filled in before its
        # own invariants read it.
        def normalize_composite_fields(aggregate, value_object, fields)
          return fields unless aggregate&.respond_to?(:value_object)

          value_object.attributes.each do |attribute|
            next if attribute.list? || !fields.key?(attribute.name)

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

        def apply_defaults(value_object, fields)
          value_object.attributes.each_with_object(fields) do |attribute, completed|
            completed[attribute.name] = attribute.default unless completed.key?(attribute.name) || attribute.default.nil?
          end
        end

        # THE FULL DOOR A VALUE OBJECT'S OWN FIELDS PASS THROUGH — shared by
        # `build` (the outer value object) and `normalize_composite_fields`
        # (every nested one), so a nested `Price`/`Size` is refused exactly
        # the same way, with exactly the same wording, as the identical type
        # declared directly on a command.
        def validate!(value_object, fields)
          admit_member(value_object, fields)
          check_admitted(value_object, fields)
          check_numeric_fields(value_object, fields)
          check_scalar_shapes(value_object, fields)
          check_patterns(value_object, fields)
          value_object.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call(invariant.canonical, fields)

            raise InvariantViolation,
                  RefusalWording.render("InvariantViolation", "value_object_invariant",
                                        name: value_object.hecks_name, description: invariant.description,
                                        offered: canonical_fields(fields))
          end
        end

        def build(value_object, fields, aggregate = nil)
          fields = apply_defaults(value_object, fields.transform_keys(&:to_sym))
          fields = normalize_composite_fields(aggregate, value_object, fields)
          validate!(value_object, fields)
          new(value_object, fields)
        end

        def hydrate(aggregate, state)
          state.each_with_object({}) do |(name, value), hydrated|
            key       = name.to_sym
            attribute = aggregate.attribute(key)
            hydrated[key] = attribute ? for_attribute(aggregate, attribute, value) : value
          end
        end

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
        def hydrate_entity_list(aggregate, attribute, value)
          entity = find_entity(aggregate, attribute.type.to_s)
          return value unless entity

          Array(value).map do |element|
            next element unless element.is_a?(Hash)

            element.each_with_object({}) do |(name, field_value), hydrated|
              key = name.to_sym
              field = entity.attribute(key)
              hydrated[key] = field ? for_attribute(aggregate, field, field_value) : field_value
            end
          end
                      .then { |hydrated| Freezer.deep(hydrated) }
        end

        # `Value.identifier` used to live here: hand it a one-field value object
        # and it opened it, so `identified_by :number` could pass for an identity
        # and the runtime would guess which field was meant. THAT GUESS IS GONE.
        # An identity names its field — `identified_by :number` — and the
        # path is what reaches the scalar. A declaration that names no field is
        # refused when the bluebook loads, so nothing has to be unwrapped later.
        #
        # `scalar` below is a different job and stays: rendering a value object
        # into a column or a message, where there is no path to consult.

        # `Value.reference_id` lived here, opening a reference to find the id
        # inside it. A reference IS the id now — refused at the payload gate if it
        # arrives as anything else — so there is nothing left to open. The comment
        # it carried said retiring it meant changing how references are STORED ;
        # that is what happened.

        # A REFERENCE IS AN ID, SO AN OBJECT IS NOT ONE.
        #
        # Nothing coerces a reference — `for_attribute` misses on
        # "Reference<Account>", which is no value object's name, and hands the
        # argument straight through. That is why the wrapped form went in
        # unnoticed for as long as it did: there was no place it could be
        # refused, so whatever the first caller wrote became the shape.
        #
        # This is that place. It sits at the payload gate rather than inside
        # coercion because the sentence names the COMMAND, and `for_attribute`
        # never learns which command it is serving.
        #
        # An Array is deliberately not refused here. A reference is never a list
        # today, and inventing a rule for a shape the language cannot declare is
        # how decoration gets written.
        def refuse_object_reference(command, attribute, value)
          return unless attribute.reference?

          offered = attribute.list? ? Array(value).find { |item| item.is_a?(Hash) || item.is_a?(self) } : value
          return unless offered.is_a?(Hash) || offered.is_a?(self)

          raise TypeMismatch,
                RefusalWording.render("TypeMismatch", "reference_as_object",
                                      command: command.hecks_name, attribute: attribute.name,
                                      known_by: known_by(attribute))
        end

        # "(Account is known by number)" — what to send instead. No article, on
        # purpose: "an Account" and "a Customer" differ by the target's first
        # letter, and a refusal pinned byte-for-byte should not hinge on an
        # article-choosing rule. Silent when the target is another chapter's,
        # where this runtime cannot see what it is known by.
        #
        # EVERY HEAD, because a caller has to pass every one. This read
        # `identified_by`, which is the SINGLE head and is nil the moment an
        # identity has two parts — so a composite target fell through the guard
        # and the refusal went silent exactly where it had the most to say. A
        # single-path target reads as it always did.
        def known_by(attribute)
          heads = Array(attribute.type.resolve&.identity_heads)
          return "" if heads.empty?

          " (#{attribute.type.target_name} is known by #{heads.join(', ')})"
        end

        def scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          return fields.values.first if fields.size == 1

          raise TypeMismatch, RefusalWording.render("TypeMismatch", "multi_field_scalar", type: value.type_name)
        end

        def from_identifier(aggregate, attribute, identifier)
          value_object = value_object_for(aggregate, attribute.type)
          return identifier unless value_object

          fields = value_object.attributes
          if fields.size == 1
            field = fields.first
            return build(value_object, { field.name => coerce_identifier(field, identifier) })
          end

          raise TypeMismatch, RefusalWording.render("TypeMismatch", "composite_identity", type: value_object.hecks_name)
        end

        # Vendored fix, not (yet) upstream hecks (migration plan
        # task 9): `identifier` here is always the DERIVED IDENTITY
        # STRING -- `Identity.of`/`Identity.from` intentionally return
        # one (correct for naming a repository key), and
        # `Runtime::Instance#materialize_identity!` calls `from_identifier`
        # with exactly that string on every fresh hydration -- but when
        # the identity field's OWN declared type is Integer/Float (not
        # the overwhelmingly common String), seeding it straight from
        # that string round-trips a correctly-derived identity back in
        # as the WRONG Ruby type -- and #build's own
        # `check_numeric_fields` (added specifically to catch a genuine
        # CALLER mismatch) then refused the runtime's OWN internal
        # identity seed instead, on every dispatch, valid input or not.
        #
        # Reuses THIS SAME FILE's own `NUMERIC` table (declared-type ->
        # expected-Ruby-class, already read by `check_numeric_fields`)
        # to decide WHICH declared types need converting, and
        # Kernel#Integer/#Float to do the converting. A genuinely
        # malformed identifier (should never happen, since an identity
        # is always derived FROM a correctly-typed field in the first
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

        def canonical_fields(fields)
          JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
        end

        # A field declared Integer or Float must ARRIVE as one.
        #
        # Without this a String sails into a numeric field and the failure surfaces
        # later, inside a predicate, as `positive? expects a number, got "three"` —
        # an EvaluationError, which is NOT a domain refusal. So the runtime broke
        # where the domain should have said no, and the run contract recorded the
        # crash beside genuine refusals as though the domain had judged it.
        #
        # Checked BEFORE invariants, because an invariant reading a mistyped field
        # is exactly the thing that used to explode.
        NUMERIC = { "Integer" => Integer, "Float" => Numeric }.freeze
        private def check_numeric_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            expected = NUMERIC[attribute.type.to_s]
            next unless expected

            given = fields[attribute.name]
            next if given.nil?

            unless given.is_a?(expected)
              raise TypeMismatch,
                    RefusalWording.render("TypeMismatch", "numeric_field",
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
            # crash, not a refusal. `-0.0` is deliberately NOT refused
            # here: it IS finite, round-trips through JSON as `-0.0`
            # cleanly (confirmed empirically), and is a legitimate,
            # meaningful float value (a signed zero), not a corruption
            # risk — only NaN and +/-Infinity are.
            if given.is_a?(Float) && !given.finite?
              raise TypeMismatch,
                    RefusalWording.render("TypeMismatch", "non_finite_field",
                                          type: value_object.hecks_name, field: attribute.name,
                                          offered: Rendering.describe(given))
            end
          end
        end

        # A field declared `String` (or a boolean) must not arrive as a
        # COMPOSITE — an Array or a Hash (or a nested Value) standing in for
        # what has to be a leaf scalar.
        #
        # Deliberately laxer than `check_numeric_fields` above : it does not
        # enforce the exact Ruby class, only that the shape isn't a collection.
        # `Judge#v` — the language's own self-hosted grammar validation —
        # hands a String-typed field (`Normalise`'s `position`, a `RuleText`)
        # a raw Integer walk-index on purpose, on every boot, and that has
        # always been tolerated ; a full String-vs-Integer check here would
        # refuse the runtime's own bootstrap. But no scalar field, of any
        # declared type, can ever legitimately be handed an Array or a Hash —
        # that shape is always wrong, and always was: `InvalidValueGenerator#
        # array_for_scalar`'s own corruption is deliberately built to be
        # REFUSED (see that file's header), and until this check existed it
        # sailed straight through for a String/boolean field the way it never
        # could for an Integer/Float one (`check_numeric_fields` above already
        # catches an Array offered for those). Found live via bin/fuzz, seed
        # 17 on the fixtures domain : an Array standing in for a single-field
        # identity's declared `String`, `.to_s`'d into a record id downstream.
        COMPOSITE_SHAPES = [Array, ::Hash].freeze
        NON_NUMERIC_SCALARS = %w[String TrueClass FalseClass].freeze
        private def check_scalar_shapes(value_object, fields)
          value_object.attributes.each do |attribute|
            next unless NON_NUMERIC_SCALARS.include?(attribute.type.to_s)

            given = fields[attribute.name]
            next if given.nil? || COMPOSITE_SHAPES.none? { |shape| given.is_a?(shape) }

            raise TypeMismatch,
                  RefusalWording.render("TypeMismatch", "numeric_field",
                                        type: value_object.hecks_name, field: attribute.name,
                                        expected: attribute.type, offered: Rendering.describe(given))
          end
        end

        # A field declared with a PATTERN must match it.
        #
        # Beside check_numeric_fields and for the same reason : a value that does
        # not look like what it claims to be is the DOMAIN saying no, and it should
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
                  RefusalWording.render("TypeMismatch", "pattern_mismatch",
                                        type: value_object.hecks_name, field: attribute.name,
                                        pattern: pattern, offered: Rendering.describe(given))
          end
        end
      end
    end
  end
end
