module Hecks
  module Bluebook
    module MetaValidator
      # The leaf shapes of a reconstructed bluebook, and the encodings that go with
      # them.
      #
      # Reconstruction walks the tree; this rebuilds the small hashes at its tips —
      # an attribute, a rule, a where-clause, a transition — and undoes the two
      # things the walk encodes on the way in: an attribute's type offered as the ID
      # of whatever it names, and an append flattened to one row per binding.
      #
      # Separate from the traversal because they are different concerns, and because
      # the two together were 211 code lines against a 200 limit.
      module Shapes
        # Rebuilds one aggregate's own attribute from its dispatched row.
        #
        # The type came in as the id of what it names, so it goes back out as the
        # name — or, for another aggregate's head, as the encoding the IR spells.
        #
        # @param field [Hash{Symbol => Object}] the dispatched `Attribute`/`Reference` row
        # @param aggregate_id [String] the owning aggregate's own id, resolving an owned
        #   value-object type back to its bare name
        # @return [Hash{Symbol => Object}] `{name:, type:, list:, default:, optional:,
        #   pattern:, admits:, relationship:}`
        def attribute(field, aggregate_id)
          type = text(field[:type]).to_s

          {
            name:         text(field[:name])&.to_sym,
            type:         owned_type(type, aggregate_id) || reference_type(type),
            list:         text(field[:list]).to_s == "true",
            default:      decode_literal(text(field[:default])),
            # Read back the same way `list` is — both are booleans about the
            # attribute, held as text, and dropping either would rebuild a
            # bluebook that no longer says what it said.
            optional:     text(field[:optional]).to_s == "true",
            pattern:      presence(text(field[:pattern])),
            # The round trip is the only way in. The grammar registry keeps the
            # assembled graph — the language as its own judge read it back — so a
            # fact dropped here is a fact no downstream projection ever sees, no
            # matter how plainly the .bluebook file declares it.
            admits:       presence(text(field[:admits])),
            relationship: presence(text(field[:relationship]))
          }
        end

        # A type this aggregate owns, offered as its id and read back as its name.
        # Prefixed with the owner and the identity join, because that is the value
        # object's identity — the aggregate it belongs to, then its name.
        #
        # @param type [String] the attribute's own type cell, an id when owned
        # @param aggregate_id [String] the owning aggregate's own id
        # @return [String, nil] the value object's own bare name, or nil when `type`
        #   does not belong to `aggregate_id`
        def owned_type(type, aggregate_id)
          prefix = Naming.identity([aggregate_id, ""])
          return nil unless type.start_with?(prefix)

          type.delete_prefix(prefix)
        end

        # One part of an identity, read back as the path it went in as. The inverse
        # of `Marks#identity_path`, and named the same so the two directions read
        # as one table.
        #
        # @param part [Hash{Symbol => Object}] one `identified_by` row
        # @return [String] the identity part's own dotted path
        def identity_path(part) = text(part[:value]).to_s

        # An argument, a parameter, a piece's attribute — the three places an
        # attribute is written that carry no owner id to strip... except a
        # piece's own attribute now does : an entity is its own root (repeating
        # the aggregate's whole shape one level down), so its attributes name a
        # value object exactly the way an aggregate's own do (`Judge#cell`'s own
        # comment), and reconstruction has to undo the same owned-vs-reference
        # split `attribute`, below, already undoes for an aggregate — not the
        # cruder "any qualified name is a Reference" guess this used before,
        # which mistook a piece's own value-object type for a cross-aggregate
        # head every time.
        #
        # `aggregate_id`, passed only for a piece's own attribute (an
        # argument or a parameter carries no value-object type at all — see
        # entity.bluebook's/command.bluebook's own comments on why — so the
        # generic reader path calls this with one argument and gets the
        # old reading unchanged), is the piece's owning aggregate — the same
        # one its own attribute types were resolved against on the way in
        # (`Judge#owning_aggregate_ref`).
        #
        # A reference among the other two came in as the head's ID, because
        # that is what Command/Query.Reference offer, so it goes back out as
        # the encoding the IR spells. A qualified name is the tell : an
        # ordinary type names something declared beside it (`Money`,
        # `AccountNumber`) and never carries a chapter, while a head's id
        # always does.
        #
        # @param field [Hash{Symbol => Object}] the dispatched argument, parameter, or
        #   piece-attribute row
        # @param aggregate_id [String, nil] the piece's own owning aggregate id, when
        #   `field` is a piece's own attribute; nil for an argument or parameter
        # @return [Hash{Symbol => Object}] `{name:, type:, list:, default:, optional:,
        #   pattern:, admits:, relationship:}`
        def shape_field(field, aggregate_id = nil)
          return attribute(field, aggregate_id) if aggregate_id

          type = text(field[:type]).to_s

          {
            name:         text(field[:name])&.to_sym,
            # A qualified name is the tell : an ordinary type names something
            # declared beside it (`Money`, `AccountNumber`) and carries no join at
            # all, where a head's id always does (chapter + name, joined the way
            # every derived id is).
            type:         type.include?(Naming::IDENTITY_JOIN) ? reference_type(type) : text(field[:type]),
            list:         text(field[:list]).to_s == "true",
            default:      decode_literal(text(field[:default])),
            optional:     text(field[:optional]).to_s == "true",
            pattern:      presence(text(field[:pattern])),
            admits:       presence(text(field[:admits])),
            relationship: presence(text(field[:relationship]))
          }
        end

        # An absent pattern is nil, not "". The language holds every field as
        # text, so a field nobody set comes back as the empty string — and ""
        # is a real regex (it matches everything), so keeping it would turn
        # "no pattern" into "a pattern that always passes" and quietly cost the
        # IR its round trip.
        #
        # @param text [String, nil] a field already read as text
        # @return [String, nil] `text`, or nil when it is nil or empty
        def presence(text)
          value = text.to_s
          value.empty? ? nil : value
        end

        # A literal, read back from the self-describing form Readings#encode_literal
        # wrote — the same reader Assembly::Marks uses, because it is the same
        # spelling. The forms are exactly the five the Primitive vocabulary admits —
        # String, Integer, Float, TrueClass, FalseClass — plus a symbol, and an
        # object literal, which is what `to: { value: "good" }` is: a value object's
        # fields written inline.
        #
        # @param text [String, nil] the self-describing wire spelling `Literal.render` wrote
        # @return [Object] nil, true, false, Integer, Float, Symbol, StateRef, String, Hash,
        #   or Array — see `Literal.read`
        def decode_literal(text) = Literal.read(text)

        # Rebuilds one precondition or invariant row.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `Rule` row
        # @return [Hash{Symbol => String}] `{description:, canonical:}`
        def rule(row) = { description: text(row[:description]), canonical: text(row[:canonical]) }

        # S12, ADR 0025 — `projects :name, from: :"reference.remote_field"`,
        # read back the same three plain identifiers `rule` above reads
        # description/canonical as.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `ProjectedField` row
        # @return [Hash{Symbol => String}] `{name:, reference:, remote_field:}`
        def projected_field(row)
          { name: text(row[:name]), reference: text(row[:reference]), remote_field: text(row[:remote_field]) }
        end

        # `provenance from: {...}` rides the same literal encoding `default:`
        # does — an object literal, self-describing via Hecks::Literal — one
        # level up: a whole keyword's argument rather than an attribute's
        # `default:`.
        #
        # @param row [Hash{Symbol => Object}] the dispatched row carrying a `provenance` cell
        # @return [Object] the decoded literal — see `decode_literal`
        def provenance(row) = decode_literal(text(row[:provenance]))

        # `command "Debit", from: "open"` — the same literal encoding
        # `provenance`/`default:` already ride (S10, ADR 0025), one
        # state or an array of them, or nil for a command with no
        # lifecycle guard.
        #
        # @param row [Hash{Symbol => Object}] the dispatched command row carrying a `from` cell
        # @return [Object] the decoded literal — see `decode_literal`
        def from(row) = decode_literal(text(row[:from]))

        # A flag is held as text ("true"/"false") and emitted as a boolean —
        # `Policy#expect_undelivered` on the wire.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `Policy` row
        # @return [Boolean] whether `row`'s own `expect_undelivered` flag was set
        def expect_undelivered?(row) = text(row[:expect_undelivered]).to_s == "true"

        # The option rows, gathered back into the shapes `extra_options_to_h` spells.
        #
        # One row per part, so a compound option is several rows and a repeated one is
        # several groups told apart by `at`. Grouping by option name and then by `at`
        # rebuilds both without either knowing which options exist — the whole point
        # of holding them as an open map.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `ReadModel` or `Query` row
        # @return [Hash{Symbol => Object}] one entry per option name, each value gathered
        #   the way `gathered` returns
        def options_of(row)
          Array(row[:options])
            .group_by { |part| text(part[:option]) }
            .to_h { |option, parts| [option.to_sym, gathered(parts)] }
        end

        # Rebuilds one option's own value: a single key/value Hash, or, when the option
        # repeats (each occurrence told apart by its own `at`), an Array of them.
        #
        # @param parts [Array<Hash{Symbol => Object}>] one option's own dispatched `Part` rows
        # @return [Hash{Symbol => String}, Array<Hash{Symbol => String}>] the option's value,
        #   or one such Hash per repetition when `parts` carry an `at`
        def gathered(parts)
          repeated, single = parts.partition { |part| !text(part[:at]).to_s.empty? }
          return single.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] } if repeated.empty?

          repeated.group_by { |part| text(part[:at]) }
                  .values
                  .map { |group| group.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] } }
        end

        # The IR keeps a where's field as a string, not a symbol — it is read back
        # out, never called. The value stays raw text here on purpose : this
        # feeds the declaration hash Assembly::Marks#where_clause decodes
        # from (via `read`), and decoding twice is worse than once — a
        # kwarg reference (":ceiling") decoded here into the Symbol :ceiling
        # would have its colon stripped by `read`'s own `.to_s` and come
        # back out as the plain string "ceiling", indistinguishable from a
        # literal of the same name. One decode, at the one place that builds
        # the object every comparator actually reads.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `Where` row
        # @return [Hash{Symbol => String}] `{field:, op:, value:}`, `value` left as raw text
        def where_clause(row)
          { field: text(row[:field]), op: text(row[:op]), value: text(row[:value]) }
        end

        # One object in the IR, two fields in the language.
        #
        # @param row [Hash{Symbol => Object}] the dispatched read-model/query row
        # @return [Hash{Symbol => String}, nil] `{field:, direction:}`, or nil when no
        #   `order_field` was declared
        def order_by(row)
          field = text(row[:order_field])
          return nil if field.to_s.empty?

          { field: field, direction: text(row[:order_way]) }
        end

        # Rebuilds a read model or query's own declared row ceiling.
        #
        # @param row [Hash{Symbol => Object}] the dispatched read-model/query row
        # @return [Hash{Symbol => String}, nil] `{value:}`, or nil when no `limit` was declared
        def limit(row)
          ceiling = text(row[:limit])
          return nil if ceiling.to_s.empty?

          { value: ceiling }
        end

        # Rebuilds one lifecycle transition row.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `Transition` row
        # @return [Hash{Symbol => String}] `{command:, from_state:, to_state:}`
        def transition(row)
          {
            command:    text(row[:command]),
            from_state: text(row[:from_state]),
            to_state:   text(row[:to_state])
          }
        end

        # Rebuilds one read-model hop or reference head.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `Hop`/reference-head row
        # @return [Hash{Symbol => Object}] `{aggregate:, as:, many:}`
        def head(row)
          {
            aggregate: text(row[:aggregate]),
            # A String, like an entity's identified_by. The IR is not uniform about
            # this and only a round trip says so.
            as:        text(row[:as]),
            many:      text(row[:many]).to_s == "true"
          }
        end

        # Rebuilds one read model's own grouping field.
        #
        # @param row [Hash{Symbol => Object}] the dispatched `GroupBy` row
        # @return [Hash{Symbol => String}] `{field:}`
        def group_by_field(row) = { field: text(row[:field]) }

        # `count`'s own boolean, read back the same way `head`'s own
        # `many` is (`text(row[:many]).to_s == "true"`) — except a
        # `ReadModel.Count` command is dispatched at all only when
        # `@count` was truthy (`MetaValidator::Judge#setters` skips a
        # setter whose every source is absent), so an undeclared read
        # model's own `count` field never gets written and comes back
        # `nil` here, never `"false"` — matching `ReadModel#to_h`'s own
        # `true`/`nil` pair (never `false`) exactly, rather than the
        # unconditional `true`/`false` `head`'s own `many` needs (every
        # head does get a `Gather` dispatch, declared or derived).
        #
        # @param row [Hash{Symbol => Object}] the dispatched `ReadModel` row
        # @return [Boolean, nil] true when `count` was declared true, nil otherwise
        def read_model_count(row) = (true if text(row[:count]).to_s == "true")

        # The append flattening, in reverse.
        #
        # An append binds several fields at once and the language's Change holds one
        # field/kind/source triple, so the walk offers an append once per binding.
        # Rebuilding groups those rows back into the single mutation the IR keeps —
        # the only place here that undoes something rather than simply reading it.
        #
        # @param row [Hash{Symbol => Object}] the dispatched command/entity row
        # @return [Array<Hash{Symbol => Object}>] one Hash per mutation, each built by `mutation`
        def mutations(row)
          Array(row[:mutations])
            .group_by { |change| [text(change[:target]), text(change[:op])] }
            .map { |(target, op), bindings| mutation(target, op, bindings) }
        end

        # `sign:` — read the same way the declared side computes it
        # (`Bluebook::Mutation.sign_for`, item #5 of the whole-project
        # table-unification survey), not stored on any row here — the
        # meta-domain's own Change entity carries no `sign` field of its
        # own (it is a pure function of `op`, nothing to persist), so
        # reconstruction recomputes it the same way a freshly-built
        # Mutation's own `to_h` lambda does, rather than leaving the key
        # silently absent (spec/round_trip_spec's whole point: a field the
        # language does not hold is a named gap, not a byte-for-byte one).
        #
        # @param target [String] the mutated field's own name, shared by every binding in
        #   `bindings`
        # @param oper [String] the mutation's own op, such as `"set"` or `"append"`
        # @param bindings [Array<Hash{Symbol => Object}>] the dispatched `Change` rows this
        #   target/op pair groups
        # @return [Hash{Symbol => Object}] `{target:, op:, sign:, fields:}` for an append,
        #   delegate, or corrects; `{target:, op:, sign:, source:}` otherwise
        def mutation(target, oper, bindings)
          base = { target: target.to_sym, op: oper.to_sym, sign: Hecks::Bluebook::Mutation.sign_for(oper) }
          # `:delegate`/`:corrects` (CommandBuilder#delegates_to's and
          # #corrects_impl's own comments) ride the same multi-binding
          # shape `:append` does.
          return base.merge(fields: appended(bindings)) if ["append", "delegate", "corrects"].include?(oper)

          base.merge(source: classified(bindings.first))
        end

        # Rebuilds the field-name-to-source map one append (or delegate/corrects) binds.
        #
        # @param bindings [Array<Hash{Symbol => Object}>] the dispatched `Change` rows one
        #   append/delegate/corrects mutation binds
        # @return [Hash{Symbol => String}] field name to source, one entry per binding
        def appended(bindings)
          bindings.to_h { |binding| [text(binding[:field]).to_sym, text(binding[:source])] }
        end

        # Rebuilds one mutation source's own kind — an argument, state, or literal reference.
        #
        # @param binding [Hash{Symbol => Object}] one dispatched `Change` row
        # @return [Hash{Symbol => Object}] `{kind:, name:}` when `binding` names an argument
        #   or state reference; `{kind: "literal", value:}` (the decoded literal) otherwise
        def classified(binding)
          kind  = text(binding[:kind])
          value = text(binding[:source])

          return { kind: kind, name: value } if %w[argument state].include?(kind)

          { kind: "literal", value: decode_literal(value) }
        end
      end
    end
  end
end
