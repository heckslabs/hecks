module Hecksagain
  module Bluebook
    module DSL
      module AttributeCollector
        ListOf = Struct.new(:type)
        OneOf  = Struct.new(:values)

        UNSET = Object.new.freeze
        private_constant :UNSET

        def attributes = @attributes ||= []

        # Value objects synthesised from inline closed sets, collected here and
        # installed by whoever owns value objects (the aggregate).
        def closed_sets = @closed_sets ||= []

        # `admits:` names a closed set that is ALREADY DECLARED elsewhere —
        #
        #   attribute :op, String, admits: "Vocabulary::QueryComparator"
        #
        # which is the difference between it and `one_of`: `one_of` SYNTHESISES
        # a fresh value object named for the attribute, so it can only ever name
        # something new. `admits` points at a set the language already holds, so
        # the same set can be named from many places without being written twice.
        #
        # QUALIFIED, because a closed set is a value object INSIDE an aggregate
        # and `reference_to` reaches heads only — so this is text, checked where
        # it is read rather than by reference resolution.
        #
        # AND WRITTEN AS TEXT, not as the constant path `Vocabulary::QueryComparator`
        # it reads like. The constant spelling was tried — `ConstShim` returning
        # a Module so Ruby's `::` reaches a second `const_missing` — and it
        # cannot hold: `Facade::Surface` installs every aggregate name as a
        # TOP-LEVEL constant, so the moment any facade exists, `Vocabulary`
        # resolves to that module and the shim is never asked. A spelling that
        # works only until a facade is built is worse than a quoted one.
        #
        # THE TYPE POSITION TAKES A BARE CONSTANT, ALWAYS REQUIRED (ADR 0025,
        # "Attributes") — omitting it (a mint default of String) and quoting
        # it as text both refuse now. Neither had a real reason left: no
        # corpus attribute ever omitted the type, and `ConstShim#const_missing`
        # (S0b) already resolves a bare, not-yet-declared constant to the
        # SAME forward reference the quoted form existed for — a bareword
        # `Name` reaches a value object named "Name" declared later in the
        # same block exactly as `"Name"` used to, `spell`'s own `to_s`
        # renders either one identically. Neither form appears in any frozen
        # era text (checked directly), so both are refused unconditionally —
        # nothing for `MetaValidator.shadow_parsing?` to answer for.
        # RENAMED FROM `attribute` — item #13's full metaprogrammed
        # dispatch (slice 3, whole-project table-unification survey).
        # The word `attribute` itself is no longer a real method any
        # builder answers directly: every (context, word) Keyword row
        # for it carries `calls: "attribute_impl"`, and `GenericDispatch`
        # forwards the whole call here untouched — this method's own
        # body is exactly what `attribute` always was, unchanged, just
        # reached generically now rather than by Ruby's own direct
        # method lookup. `attribute_collector_spec.rb` (`AttributeCollector
        # has no method without a test` — dsl_coverage_spec.rb) and the
        # bootstrap fallback (`GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`) both
        # name this same string; they must never drift apart.
        def attribute_impl(name, type = UNSET, default: nil, optional: false, pattern: nil,
                           admits: nil, one_of: nil)
          # moved to the language: FieldName invariant, on Root.Attribute

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

        # RENAMED FROM `list_of` — item #13's full metaprogrammed
        # dispatch (slice 5). Called in an attribute's own TYPE
        # position (`attribute :x, list_of(Y)`), never through a `def
        # list_of` any ONE builder answers as its own word — reached
        # via `WordGate#word_gate_dispatch`'s new "Type"-context
        # fallback, the same one `one_of_impl` below uses. Bootstrap-
        # reachable (every core chapter's own list-typed attributes use
        # it), so `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK` carries a
        # SINGLE `["Type", "list_of"]` entry rather than one per calling
        # context — the bootstrap branch checks that key too now, same
        # reasoning as the ordinary fallback.
        def list_of_impl(type) = ListOf.new(type)

        # `reference_to Account` MINTS `:account` — no `_id` — the default
        # every `reference_to`-shaped word (`AggregateBuilder`,
        # `EntityBuilder`, `CommandBuilder#cross_reference`,
        # `QueryBuilder`, `PortOperationBuilder`, all `include
        # AttributeCollector`) shares, since dropping the suffix is what
        # makes `/` a real traversal operator possible at all (ADR 0025,
        # "References" — a hop crosses at `/`, a field walk crosses at
        # `.`; deriving the hop name from `account_id` is what made an
        # explicit operator impossible before).
        #
        # LEGACY UNDER SHADOW-PARSING (S0a's own bridge): frozen era text
        # was minted under the OLD default, and `EraGuard.shadow_parse`
        # reconstructs a held aggregate's shape to DIFF against the
        # current one — reading that text through the NEW default would
        # silently reconstruct the WRONG historical name, not merely
        # refuse a spelling the way S1's `identified_by` legacy forms do.
        # This is a mint DEFAULT changing, not a syntax being removed, so
        # there is nothing to refuse here — only a fork in what gets
        # minted when `as:` is omitted.
        private def default_reference_name(target)
          suffix = MetaValidator.shadow_parsing? ? "_id" : ""
          :"#{Naming.snake(target)}#{suffix}"
        end

        # A closed set declared INLINE on the attribute:
        #
        #   attribute :status, one_of("open", "shut")
        #
        # Desugars to a value object named for the attribute, so it goes through
        # exactly the machinery a hand-written one_of does — and so the
        # attribute's type is still a DECLARED value object, which is now a
        # structural rule rather than a predicate.
        #
        # An earlier reading of this spelling parsed it and threw the values
        # away: the attribute became a plain String and the closed set meant
        # nothing, in a construct that looked supported. The desugaring is
        # pinned now — the same bluebook must always yield the same IR.
        # RENAMED FROM `one_of` — item #13's full metaprogrammed dispatch
        # (slice 5), same reasoning as list_of_impl above. SAME NAME as
        # `ValueObjectBuilder#one_of_impl`'s own override on purpose —
        # that method's own `super(*values)` call (the no-block, bare
        # type-position case) resolves by METHOD NAME up the ancestor
        # chain, and renaming only one side would silently break it.
        def one_of_impl(*values) = OneOf.new(values)

        private

        # `one_of:` NAMES A CLOSED SET ON THE FIELD ITSELF (ADR 0025,
        # "Attributes") — joining `pattern:`/`admits:` where value
        # constraints already live, for the one context where it means
        # anything: a `value_object` block, where it replaces the old
        # `one_of do member ... end` wrapper for a SINGLE-FIELD set (a
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

        # A pattern is refused AT DECLARATION, not when a value first meets it :
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

        # `identified_by :reference` — DERIVING the path instead of spelling
        # it: `field`'s own already-declared attribute names a value
        # object, and when that value object holds EXACTLY one field there
        # is only one thing the identity could ever mean. More than one
        # field is genuinely ambiguous (which one names the record?) —
        # refused, naming every candidate, rather than guessing
        # `.value`-if-present the way an earlier draft of this did
        # (silently wrong the moment a second field, `pad`, arrives on
        # what used to be single-field).
        #
        # AN IDENTITY HEAD IS A SINGLE-FIELD VALUE OBJECT (auto-unwrapped
        # here), A BARE SCALAR, OR A REFERENCE (ADR 0025, "References") —
        # never a list, never a multi-field value object. A reference is
        # already a scalar id the moment it is stored (`reference_to`
        # mints a bare attribute, never a nested object), so it resolves
        # to its own name unchanged, the same as a primitive.
        #
        # Shared by AggregateBuilder and EntityBuilder (both include this
        # module) — each resolves it at its own BUILD time, not at
        # `identified_by`'s own call time, since every real bluebook
        # declares identified_by BEFORE the attribute it names, so the
        # attribute (and its own value-object type) don't exist to look up
        # yet at that point.
        def resolve_identity_field!(field, value_objects, context_name)
          attr = attributes.find { |a| a.name == field }

          # `:id` OR AN `_id`-SUFFIXED NAME WITH NO MATCHING ATTRIBUTE is
          # not a typo to refuse — it is the language's own WALK-PARENT/
          # FALLBACK-IDENTITY convention. The `_id` suffix is the meta-
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

          if attr.list?
            raise Malformed,
                  "#{context_name}.identified_by :#{field} names a list — an identity must be " \
                  "a single value, and a list is never one"
          end

          return [field.to_s] if attr.reference?

          vo = value_objects.find { |v| v.hecks_name.to_s == attr.type.to_s }
          return [field.to_s] unless vo # a bare primitive type — already itself scalar

          case vo.attributes.size
          when 1
            ["#{field}.#{vo.attributes.first.name}"]
          else
            raise Malformed,
                  "#{context_name}.identified_by :#{field} names #{attr.type}, which has " \
                  "#{vo.attributes.size} fields (#{vo.attributes.map(&:name).join(', ')}) — " \
                  "a bare field name only derives an identity when its own value object has " \
                  "exactly one field; give #{context_name} a single-field identity of its own " \
                  "instead"
          end
        end

        # `identified_by PizzaName` — the bare-TYPE form, mirroring
        # `reference_to`'s own shape exactly: pass the value object, not a
        # field name, and the attribute itself is MINTED here (no separate
        # `attribute :name, PizzaName` line needed at all) the same way
        # `reference_to Team` mints `:team_id` on its own. The minted
        # attribute's own name is `as:` if given, or `Naming.snake` of the
        # type otherwise — same convention `reference_to`'s own `as:`
        # already uses. Requires EXACTLY one field on the value object, for
        # the identical reason `resolve_identity_field!` does — refused,
        # naming every candidate, rather than guessing.
        def resolve_identity_type!(type, as, insert_at, value_objects, context_name)
          target = Naming.demodulise(type)
          vo = value_objects.find { |v| v.hecks_name.to_s == target }
          raise Malformed, "#{context_name}.identified_by names #{target}, which is not a declared value object" unless vo

          if vo.attributes.size != 1
            raise Malformed,
                  "#{context_name}.identified_by names #{target}, which has #{vo.attributes.size} " \
                  "fields (#{vo.attributes.map(&:name).join(', ')}) — identified_by ValueObject only " \
                  "derives a path when it has exactly one field; write identified_by { field.<field> } " \
                  "naming the specific one"
          end

          field = (as || Naming.snake(target)).to_sym
          # `Attribute.new` DIRECTLY, not the public `attribute(...)` DSL
          # entry — `target` is `Naming.demodulise`'d TEXT, not a bareword
          # the bluebook author typed (the type position's own quoted-text
          # refusal is about DSL source, not internal minting), and `vo`
          # ITSELF can't be passed either: it is the real, already-built
          # `ValueObject` subclass, permanently anonymous from Ruby's own
          # `to_s` (only `hecks_name` carries its name) — `Attribute#spell`
          # would demodulise it to "#<Class:0x...>", not "PizzaName".
          attributes << Attribute.new(name: field, type: target)
          # MOVED to `insert_at` — the attribute count AT THE MOMENT
          # `identified_by` was actually called, captured by the caller —
          # not left where `attribute` just appended it. Resolution happens
          # at BUILD time, after every other attribute in the block has
          # already run, so appending would put the identity field LAST
          # regardless of where `identified_by` was actually written.
          # Most real bluebooks write it first (insert_at 0); one (a
          # ScheduledPayment corpus member) writes it after a reference_to
          # and an attribute — this matches either, and whatever a person
          # hand-writing `attribute field, Type` at that exact point,
          # the way this used to be required, would have produced.
          attributes.insert(insert_at, attributes.pop)
          ["#{field}.#{vo.attributes.first.name}"]
        end
      end
    end
  end
end
