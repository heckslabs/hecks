module Hecks
  module Bluebook
    module DSL
      # Shared mixin for every DSL builder that declares attributes
      # (Aggregate/Entity/Command/Query/PortOperation/ValueObject) — the
      # `attribute`/`list_of`/`one_of` words themselves, closed-set
      # synthesis, duplicate-name and pattern refusals, and the
      # `identified_by` field/type resolution both a construct's own
      # identity and a compound key are built from.
      module AttributeCollector
        ListOf = Struct.new(:type)
        # `:values` shadows Struct#values on purpose — with one member, the
        # generated accessor returns the flat array of permitted values
        # directly (what every caller actually wants), not Struct#values'
        # own `[self.values]`. No caller anywhere reads the built-in
        # behavior; verified before disabling this cop for it.
        # rubocop:disable-next Lint/StructNewOverride
        OneOf  = Struct.new(:values)

        UNSET = Object.new.freeze
        private_constant :UNSET

        # Every attribute declared on this construct so far, in declaration order.
        #
        # @return [Array<Bluebook::Attribute>] the accumulated attributes; empty before any
        #   `attribute`/`identified_by`/`reference_to` call
        def attributes = @attributes ||= []

        # Value objects synthesised from inline closed sets, collected here and
        # installed by whoever owns value objects (the aggregate).
        #
        # @return [Array<Bluebook::ValueObject>] the closed sets synthesised so far from this
        #   construct's own `one_of(...)` type-position calls; empty until one is used
        def closed_sets = @closed_sets ||= []

        # `admits:` names a closed set that is already declared elsewhere —
        #
        #   attribute :op, String, admits: "Vocabulary::QueryComparator"
        #
        # which is the difference between it and `one_of`: `one_of` synthesises
        # a fresh value object named for the attribute, so it can only ever name
        # something new. `admits` points at a set the language already holds, so
        # the same set can be named from many places without being written twice.
        #
        # Qualified, because a closed set is a value object inside an aggregate
        # and `reference_to` reaches heads only — so this is text, checked where
        # it is read rather than by reference resolution.
        #
        # And written as text, not as the constant path `Vocabulary::QueryComparator`
        # it reads like. The constant spelling was tried — `ConstShim` returning
        # a Module so Ruby's `::` reaches a second `const_missing` — and it
        # cannot hold: `Facade::Surface` installs every aggregate name as a
        # top-level constant, so the moment any facade exists, `Vocabulary`
        # resolves to that module and the shim is never asked. A spelling that
        # works only until a facade is built is worse than a quoted one.
        #
        # The type position takes a bare constant, always required (ADR 0025,
        # "Attributes") — omitting it (a mint default of String) and quoting
        # it as text both refuse now. Neither had a real reason left: no
        # corpus attribute ever omitted the type, and `ConstShim#const_missing`
        # (S0b) already resolves a bare, not-yet-declared constant to the
        # same forward reference the quoted form existed for — a bareword
        # `Name` reaches a value object named "Name" declared later in the
        # same block, and `spell`'s own `to_s` renders a bareword and quoted
        # text identically. Neither form appears in any frozen
        # era text (checked directly), so both are refused unconditionally.
        #
        # Answers the `attribute` word through the table's `calls:` column —
        # item #13's full metaprogrammed dispatch (slice 3, whole-project
        # table-unification survey). The word `attribute` itself is no
        # longer a real method any builder answers directly: every
        # (context, word) Keyword row for it carries `calls: "attribute_impl"`,
        # and `GenericDispatch` forwards the whole call here untouched — this
        # method's own body is exactly what `attribute` always was, unchanged,
        # just reached generically now rather than by Ruby's own direct
        # method lookup. `attribute_collector_spec.rb` (`AttributeCollector
        # has no method without a test` — dsl_coverage_spec.rb) and the
        # bootstrap fallback (`GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`) both
        # name this same string; they must never drift apart.
        #
        # @param name [Symbol, String] the attribute's name
        # @param type [Module, Bluebook::Reference, Bluebook::DSL::AttributeCollector::ListOf,
        #   Bluebook::DSL::AttributeCollector::OneOf] the bare constant naming a primitive or a
        #   value object, a `reference_to`-built Reference, or a `list_of`/`one_of` wrapper
        # @param default [Object, nil] the value a new record starts with when none is given
        # @param optional [Boolean] whether the attribute may be absent
        # @param pattern [String, nil] a regex source the value must match; shared-engine subset
        #   only (`PatternSubset`)
        # @param admits [String, nil] an already-declared closed set's aggregate-qualified name,
        #   such as `"Vocabulary::QueryComparator"`, that the value must belong to
        # @param one_of [Bluebook::DSL::AttributeCollector::OneOf, nil] set only by the deprecated
        #   `one_of:` keyword; always refused outside `ValueObjectBuilder`
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `name` is already declared, `type` is omitted or
        #   given as quoted text, `pattern` uses a construct `PatternSubset` refuses, or `one_of:`
        #   is used outside a `value_object` block
        def attribute_impl(name, type = UNSET, default: nil, optional: false, pattern: nil,
                           admits: nil, one_of: nil)
          # moved to the language: FieldName invariant, on Root.Attribute

          refuse_duplicate_attribute!(name)

          if type.equal?(UNSET)
            raise Malformed, "#{name} declares no type — attribute :#{name}, SomeType is required, " \
                             "there is no default"
          end

          # `list_of("X")` carries the same quoted text one level down — a
          # bare constant is required there too, checked before it unwraps
          # below, not after (once unwrapped, a plain String in the `type:`
          # slot looks identical to one that legitimately belongs there).
          quoted = type.is_a?(ListOf) ? type.type : type
          if quoted.is_a?(::String)
            raise Malformed, "#{name}'s type #{quoted.inspect} is quoted text — give the bare constant " \
                             "(#{quoted}) instead; a forward reference to a value object declared later " \
                             "in the same block already resolves without quoting"
          end

          refuse_unshared_pattern(name, pattern) if pattern

          type = synthesise_closed_set(name, type) if type.is_a?(OneOf)
          list = type.is_a?(ListOf)
          attributes << Attribute.new(
            name:     name,
            type:     list ? type.type : type,
            list:     list,
            default:  default,
            optional: optional,
            pattern:  pattern,
            admits:   admits
          )

          install_inline_closed_set(name, one_of) if one_of
        end

        # Wraps a type so `attribute_impl` builds a list-typed attribute instead of a scalar one.
        #
        # Answers the `list_of` word through the table's `calls:` column —
        # item #13's full metaprogrammed dispatch (slice 5). Called in an
        # attribute's own type
        # position (`attribute :x, list_of(Y)`), never through a `def
        # list_of` any one builder answers as its own word — reached
        # via `WordGate#word_gate_dispatch`'s "Type"-context
        # fallback, the same one `one_of_impl` below uses. Bootstrap-
        # reachable (every core chapter's own list-typed attributes use
        # it), so `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` carries a
        # single `["Type", "list_of"]` entry rather than one per calling
        # context — the bootstrap branch checks that key too now, same
        # reasoning as the ordinary fallback.
        #
        # @param type [Module, Bluebook::Reference] the bare constant naming the list's element
        #   type
        # @return [Bluebook::DSL::AttributeCollector::ListOf] the wrapped type, for `attribute_impl`
        #   to unwrap
        def list_of_impl(type) = ListOf.new(type)

        # `reference_to Account` mints `:account` — no `_id` — the default
        # every `reference_to`-shaped word (`AggregateBuilder`,
        # `EntityBuilder`, `CommandBuilder#cross_reference`,
        # `QueryBuilder`, `PortOperationBuilder`, all `include
        # AttributeCollector`) shares, since dropping the suffix is what
        # makes `/` a real traversal operator possible at all (ADR 0025,
        # "References" — a hop crosses at `/`, a field walk crosses at
        # `.`; deriving the hop name from `account_id` is what made an
        # explicit operator impossible before).
        #
        # Legacy under shadow-parsing (S0a's own bridge): frozen era text
        # was minted under the old default, and `EraGuard.shadow_parse`
        # reconstructs a held aggregate's shape to diff against the
        # current one — reading that text through the new default would
        # silently reconstruct the wrong historical name, not merely
        # refuse a spelling the way S1's `identified_by` legacy forms do.
        # This is a mint default changing, not a syntax being removed, so
        # there is nothing to refuse here — only a fork in what gets
        # minted when `as:` is omitted.
        private def default_reference_name(target)
          suffix = MetaValidator.shadow_parsing? ? "_id" : ""
          :"#{Naming.snake(target)}#{suffix}"
        end

        # A closed set declared inline on the attribute:
        #
        #   attribute :status, one_of("open", "shut")
        #
        # Desugars to a value object named for the attribute, so it goes through
        # exactly the machinery a hand-written one_of does — and so the
        # attribute's type is still a declared value object, which is now a
        # structural rule rather than a predicate.
        #
        # An earlier reading of this spelling parsed it and threw the values
        # away: the attribute became a plain String and the closed set meant
        # nothing, in a construct that looked supported. The desugaring is
        # pinned now — the same bluebook must always yield the same IR.
        #
        # Answers the `one_of` word through the table's `calls:` column —
        # item #13's full metaprogrammed dispatch (slice 5), same reasoning
        # as `list_of_impl` above. Same name as
        # `ValueObjectBuilder#one_of_impl`'s own override on purpose —
        # that method's own `super(*values)` call (the no-block, bare
        # type-position case) resolves by method name up the ancestor
        # chain, and renaming only one side would silently break it.
        #
        # @param values [Array<String, Symbol>] the permitted values, at least one
        # @return [Bluebook::DSL::AttributeCollector::OneOf] the wrapped values, for
        #   `attribute_impl` to synthesise a closed set from
        def one_of_impl(*values) = OneOf.new(values)

        private

        def relationship_attribute(target, kind, name, optional: false, list: false)
          refuse_duplicate_attribute!(name)
          attributes << Attribute.new(
            name:         name,
            type:         Reference.new(target),
            list:         list,
            optional:     optional,
            relationship: kind
          )
        end

        # `one_of:` names a closed set on the field itself (ADR 0025,
        # "Attributes") — joining `pattern:`/`admits:` where value
        # constraints already live, for the one context where it means
        # anything: a `value_object` block, where it replaces the old
        # `one_of do member ... end` wrapper for a single-field set (a
        # multi-field set still writes bare `member` lines, unwrapped).
        # `ValueObjectBuilder` overrides this; every other includer
        # (Aggregate/Entity/Command/Query/PortOperation) inherits this
        # refusal — those contexts already have the unchanged type-position
        # form (`attribute :status, one_of("open", "shut")`) for an
        # anonymous inline set, so `one_of:` naming a *field* there would be
        # a second spelling of the same idea, not a new one.
        def install_inline_closed_set(name, _values)
          raise Malformed,
                "#{name}'s one_of: only means something inside a value_object — name a closed set " \
                "with the type-position one_of(...) instead"
        end

        # A name declared twice on the same owner is two attributes sharing
        # one name, and nothing downstream disambiguates them — every
        # reader that walks `attributes` looking for one by name
        # (`seal_mutation_targets`, `seal_query_field`, `projects`'s own
        # local check, `Instance#[]`, ...) uses `Array#find`/`any?`, which
        # silently answers whichever declaration happens to come first and
        # discards the second — a bluebook with the duplicate boots clean,
        # and both declarations survive into the IR, one of them permanently
        # unreachable by name. Refused here, at the one place every owner
        # (Aggregate/Entity/Command/Query/PortOperation/ValueObject, each
        # `include AttributeCollector`) mints an attribute through, rather
        # than taught to each of those readers individually.
        def refuse_duplicate_attribute!(name)
          return unless attributes.any? { |attribute| attribute.name == name }

          raise Malformed, "#{name} is declared twice — an attribute name is declared once, not twice"
        end

        # A pattern is refused at declaration, not when a value first meets it :
        # a regex whose meaning depends on which engine reads it is a defect in
        # the bluebook, and a bluebook that loads is one whose patterns carry
        # one meaning. PatternSubset says which those are, and why each is refused.
        def refuse_unshared_pattern(name, pattern)
          rejection = PatternSubset.validate(pattern)
          return unless rejection

          raise Malformed,
                "#{name}'s pattern #{pattern.inspect} uses a #{rejection.construct} — " \
                "#{rejection.reason}"
        end

        def synthesise_closed_set(name, one_of)
          type = Naming.pascal(name)
          closed_sets << ValueObject.declare(
            name:       type,
            attributes: [Attribute.new(name: :value, type: "String")],
            members:    one_of.values.map { |value| { value: value.to_s } },
            closed_set: true
          )
          type
        end

        # Every selected identity head contributes all of its recursively
        # scalar leaves in declaration order. Named, inline and compound-key
        # declarations therefore share one flattening rule.
        def resolve_identity_field!(field, value_objects, context_name)
          attr = attributes.find { |a| a.name == field }

          # `:id` or an `_id`-suffixed name with no matching attribute is
          # not a typo to refuse — it is the language's own walk-parent/
          # fallback-identity convention. The `_id` suffix is the meta-
          # domain's own (the `Command`/`Entity`/`Aggregate` etc. records
          # identify by `owner_id`/`bluebook_id`/`aggregate_id`, supplied
          # by the judge's replay rather than declared locally — see
          # `behavior.bluebook`'s own "owner_id is not a declared
          # attribute" comment); bare `:id` is `Instance#materialize_
          # identity!`'s own fallback name (`@aggregate.identified_by ||
          # :id`) made explicit rather than left implicit — declaring
          # `identified_by :id` says out loud what omitting `identified_by`
          # entirely already meant. `reference_to` mints the `_id` suffix
          # for the same reason `attr.reference?` below resolves bare: an
          # `_id`(-shaped) name is already a scalar by the language's own
          # spelling convention, walk-supplied or locally declared alike.
          return [field.to_s] if attr.nil? && (field.to_s == "id" || field.to_s.end_with?("_id"))

          raise Malformed, "#{context_name}.identified_by :#{field} names no attribute #{context_name} declares" unless attr

          identity_paths_for_attribute(attr, value_objects, context_name, field.to_s, [])
        end

        # A named or inline identity mints one structured field, then expands
        # each scalar leaf beneath it into the existing path-shaped IR.
        def resolve_identity_type!(type, as, insert_at, value_objects, context_name)
          target = Naming.demodulise(type.respond_to?(:hecks_name) ? type.hecks_name : type)
          matches = value_objects.select { |value_object| value_object.hecks_name.to_s == target }
          raise Malformed, "#{context_name}.identified_by names duplicate value object #{target}" if matches.size > 1

          vo = type.respond_to?(:attributes) ? type : matches.first
          raise Malformed, "#{context_name}.identified_by names #{target}, which is not a declared value object" unless vo
          raise Malformed, "#{context_name}.identified_by names #{target}, which declares no attributes" if vo.attributes.empty?

          field = (as || Naming.snake(target)).to_sym
          if attributes.any? { |attribute| attribute.name == field }
            raise Malformed,
                  "#{context_name}.identified_by #{target} mints :#{field}, but that attribute is already declared"
          end

          # `Attribute.new` directly, not the public `attribute(...)` DSL
          # entry — `target` is `Naming.demodulise`'d text, not a bareword
          # the bluebook author typed (the type position's own quoted-text
          # refusal is about DSL source, not internal minting), and `vo`
          # itself can't be passed either: it is the real, already-built
          # `ValueObject` subclass, permanently anonymous from Ruby's own
          # `to_s` (only `hecks_name` carries its name) — `Attribute#spell`
          # would demodulise it to "#<Class:0x...>", not "PizzaName".
          attributes << Attribute.new(name: field, type: target)
          # Moved to `insert_at` — the attribute count at the moment
          # `identified_by` was actually called, captured by the caller —
          # not left where `attribute` just appended it. Resolution happens
          # at build time, after every other attribute in the block has
          # already run, so appending would put the identity field last
          # regardless of where `identified_by` was actually written.
          # Most real bluebooks write it first (insert_at 0); one (a
          # ScheduledPayment corpus member) writes it after a reference_to
          # and an attribute — this matches either, and matches what a
          # person hand-writing `attribute field, Type` at that exact
          # point would produce.
          attributes.insert(insert_at, attributes.pop)
          vo.attributes.flat_map do |attribute|
            identity_paths_for_attribute(attribute, value_objects, context_name,
                                         "#{field}.#{attribute.name}", [target])
          end
        end

        def identity_paths_for_attribute(attribute, value_objects, context_name, path, visited)
          if attribute.list?
            raise Malformed,
                  "#{context_name}'s identity member #{path} is a list — an identity member must be scalar"
          end
          if attribute.optional?
            raise Malformed,
                  "#{context_name}'s identity member #{path} is optional — an identity must be wholly known"
          end

          return [path] if attribute.reference?

          nested = value_objects.find { |value_object| value_object.hecks_name.to_s == attribute.type.to_s }
          return [path] unless nested

          if visited.include?(nested.hecks_name.to_s)
            cycle = [*visited, nested.hecks_name.to_s].join(" -> ")
            raise Malformed, "#{context_name}'s identity value objects form a cycle: #{cycle}"
          end

          # **A bare field derives one scalar**. `identified_by :ref` (or one leg
          # of a compound `identified_by :a, :b`) names a single field, and
          # deriving its path only makes sense while every value object along
          # the way wraps exactly one field itself — the same "single-field
          # value object" ADR 0025 names this shape after. A multi-field
          # value object here is refused rather than expanded silently into
          # every one of its own fields, which would mint an unannounced
          # compound key nothing declared.
          if nested.attributes.size != 1
            candidates = nested.attributes.map(&:name).join(", ")
            raise Malformed,
                  "#{context_name}.identified_by :#{path} names #{nested.hecks_name}, which has " \
                  "#{nested.attributes.size} field#{'s' unless nested.attributes.size == 1} (#{candidates})"
          end

          member = nested.attributes.first
          identity_paths_for_attribute(member, value_objects, context_name, "#{path}.#{member.name}",
                                       [*visited, nested.hecks_name.to_s])
        end
      end
    end
  end
end
