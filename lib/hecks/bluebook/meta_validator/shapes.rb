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
        # The type came in as the id of what it names, so it goes back out as the
        # name — or, for another aggregate's head, as the encoding the IR spells.
        #
        # @param field [Hash{Symbol => Object}] one dispatched attribute row
        # @param aggregate_id [String] the owning aggregate's own id, to
        #   strip from an owned value-object type
        # @return [Hash{Symbol => Object}] `:name` (`Symbol`, `nil`),
        #   `:type` (`String`), `:list`/`:optional` (`Boolean`), `:default`
        #   (decoded literal, `nil` when absent), `:pattern`/`:admits`/
        #   `:relationship` (`String`, `nil` when absent)
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
        # @param type [String] the attribute's own dispatched `type` cell
        # @param aggregate_id [String] the owning aggregate's own id
        # @return [String, nil] `type` with the owner's own identity prefix
        #   stripped, or `nil` if `type` does not carry that prefix (an
        #   ordinary type name, or a cross-aggregate reference)
        def owned_type(type, aggregate_id)
          prefix = Naming.identity([aggregate_id, ""])
          return nil unless type.start_with?(prefix)

          type.delete_prefix(prefix)
        end

        # One part of an identity, read back as the path it went in as. The inverse
        # of `Marks#identity_path`, and named the same so the two directions read
        # as one table.
        #
        # @param part [Hash{Symbol => Object}] one dispatched identity-part row
        # @return [String] the identity part's own path text
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
        # @param field [Hash{Symbol => Object}] one dispatched attribute,
        #   argument, or parameter row
        # @param aggregate_id [String, nil] the piece's own owning
        #   aggregate id, passed only for a piece's own attribute
        # @return [Hash{Symbol => Object}] `:name` (`Symbol`, `nil`),
        #   `:type` (`String`), `:list`/`:optional` (`Boolean`), `:default`
        #   (decoded literal, `nil` when absent), `:pattern`/`:admits`/
        #   `:relationship` (`String`, `nil` when absent)
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
        # @param text [String, nil] a dispatched cell's own already-unwrapped
        #   text
        # @return [String, nil] `text`, or `nil` when `text` is `nil` or
        #   empty
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
        # @param text [String, nil] the self-describing wire spelling
        #   `Readings#encode_literal` wrote
        # @return [Object] `nil`, `true`, `false`, `Integer`, `Float`,
        #   `Symbol`, `Hecks::StateRef`, `String`, `Hash`, or `Array` — or
        #   `text` itself, stripped, when it matches no known spelling
        def decode_literal(text) = Literal.read(text)

        # Reads a rule's plain description/canonical pair, for a
        # `given`/`invariant`/`ensures`.
        #
        # @param row [Hash{Symbol => Object}] one dispatched rule row
        # @return [Hash{Symbol => String}] `:description` and `:canonical`
        def rule(row) = { description: text(row[:description]), canonical: text(row[:canonical]) }

        # S12, ADR 0025 — `projects :name, from: :"reference.remote_field"`,
        # read back the same three plain identifiers `rule` above reads
        # description/canonical as.
        #
        # @param row [Hash{Symbol => Object}] one dispatched projected-field
        #   row
        # @return [Hash{Symbol => String}] `:name`, `:reference`, and
        #   `:remote_field`
        def projected_field(row)
          { name: text(row[:name]), reference: text(row[:reference]), remote_field: text(row[:remote_field]) }
        end

        # `provenance from: {...}` rides the same literal encoding `default:`
        # does — an object literal, self-describing via Hecks::Literal — one
        # level up: a whole keyword's argument rather than an attribute's
        # `default:`.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying a
        #   `:provenance` cell
        # @return [Object] the decoded `from:` object literal, or `nil` when
        #   absent
        def provenance(row) = decode_literal(text(row[:provenance]))

        # `command "Debit", from: "open"` — the same literal encoding
        # `provenance`/`default:` already ride (S10, ADR 0025), one
        # state or an array of them, or nil for a command with no
        # lifecycle guard.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying a
        #   `:from` cell
        # @return [String, Array<String>, nil] the decoded lifecycle guard
        #   state(s), or `nil` for a command with no lifecycle guard
        def from(row) = decode_literal(text(row[:from]))

        # A flag is held as text ("true"/"false") and emitted as a boolean —
        # `Policy#expect_undelivered` on the wire.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying an
        #   `:expect_undelivered` cell
        # @return [Boolean] whether the flag reads `"true"`
        def expect_undelivered?(row) = text(row[:expect_undelivered]).to_s == "true"

        # The option rows, gathered back into the shapes `extra_options_to_h` spells.
        #
        # One row per part, so a compound option is several rows and a repeated one is
        # several groups told apart by `at`. Grouping by option name and then by `at`
        # rebuilds both without either knowing which options exist — the whole point
        # of holding them as an open map.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying an
        #   `:options` list
        # @return [Hash{Symbol => Object}] one entry per option name; each
        #   value is `gathered`'s own return for that option's own parts
        def options_of(row)
          Array(row[:options])
            .group_by { |part| text(part[:option]) }
            .to_h { |option, parts| [option.to_sym, gathered(parts)] }
        end

        # Groups one option's own dispatched parts back into a single
        # binding, or several `at`-keyed groups for a repeated option.
        #
        # @param parts [Array<Hash{Symbol => Object}>] one option's own
        #   dispatched key/value/at rows
        # @return [Hash{Symbol => String}, Array<Hash{Symbol => String}>]
        #   a single `key => value` hash when no part carries `at`;
        #   otherwise an array of such hashes, one per distinct `at`
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
        # @param row [Hash{Symbol => Object}] one dispatched where-clause row
        # @return [Hash{Symbol => String}] `:field`, `:op`, and `:value`
        #   (raw text, undecoded)
        def where_clause(row)
          { field: text(row[:field]), op: text(row[:op]), value: text(row[:value]) }
        end

        # One object in the IR, two fields in the language.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying
        #   `:order_field`/`:order_way` cells
        # @return [Hash{Symbol => String}, nil] `:field` and `:direction`,
        #   or `nil` when no `order_field` was declared
        def order_by(row)
          field = text(row[:order_field])
          return nil if field.to_s.empty?

          { field: field, direction: text(row[:order_way]) }
        end

        # Reads a read model's own declared row limit.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying a
        #   `:limit` cell
        # @return [Hash{Symbol => String}, nil] `{value: ceiling}`, or `nil`
        #   when no limit was declared
        def limit(row)
          ceiling = text(row[:limit])
          return nil if ceiling.to_s.empty?

          { value: ceiling }
        end

        # Reads one lifecycle transition row.
        #
        # @param row [Hash{Symbol => Object}] one dispatched lifecycle
        #   transition row
        # @return [Hash{Symbol => String}] `:command`, `:from_state`, and
        #   `:to_state`
        def transition(row)
          {
            command:    text(row[:command]),
            from_state: text(row[:from_state]),
            to_state:   text(row[:to_state])
          }
        end

        # Reads one reference head — a process manager handler's own
        # aggregate binding.
        #
        # @param row [Hash{Symbol => Object}] one dispatched reference-head
        #   row
        # @return [Hash{Symbol => Object}] `:aggregate`/`:as` (`String`) and
        #   `:many` (`Boolean`)
        def head(row)
          {
            aggregate: text(row[:aggregate]),
            # A String, like an entity's identified_by. The IR is not uniform about
            # this and only a round trip says so.
            as:        text(row[:as]),
            many:      text(row[:many]).to_s == "true"
          }
        end

        # Reads a read model's own `group_by` field name.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying a
        #   `:field` cell
        # @return [Hash{Symbol => String}] `{field: ...}`
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
        # @param row [Hash{Symbol => Object}] a dispatched row carrying a
        #   `:count` cell
        # @return [Boolean, nil] `true` when the flag reads `"true"`, `nil`
        #   for an undeclared read model's own `count`
        def read_model_count(row) = (true if text(row[:count]).to_s == "true")

        # The append flattening, in reverse.
        #
        # An append binds several fields at once and the language's Change holds one
        # field/kind/source triple, so the walk offers an append once per binding.
        # Rebuilding groups those rows back into the single mutation the IR keeps —
        # the only place here that undoes something rather than simply reading it.
        #
        # @param row [Hash{Symbol => Object}] a dispatched row carrying a
        #   `:mutations` list
        # @return [Array<Hash{Symbol => Object}>] one hash per distinct
        #   `target`/`op` pair, each `mutation`'s own return
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
        # @param target [String] the mutated field's own name
        # @param oper [String] the mutation's operation name, such as
        #   `"set"`, `"append"`, `"delegate"`, or `"corrects"`
        # @param bindings [Array<Hash{Symbol => Object}>] this target/op
        #   pair's own dispatched binding rows
        # @return [Hash{Symbol => Object}] `:target`/`:op` (`Symbol`),
        #   `:sign` (`String`), plus `:fields` (`appended`'s own return) for
        #   `"append"`/`"delegate"`/`"corrects"`, or `:source`
        #   (`classified`'s own return) for anything else
        def mutation(target, oper, bindings)
          base = { target: target.to_sym, op: oper.to_sym, sign: Hecks::Bluebook::Mutation.sign_for(oper) }
          # `:delegate`/`:corrects` (CommandBuilder#delegates_to's and
          # #corrects_impl's own comments) ride the same multi-binding
          # shape `:append` does.
          return base.merge(fields: appended(bindings)) if ["append", "delegate", "corrects"].include?(oper)

          base.merge(source: classified(bindings.first))
        end

        # Rebuilds an append's own field -> source map from its flattened
        # per-binding rows.
        #
        # @param bindings [Array<Hash{Symbol => Object}>] one append's own
        #   dispatched binding rows
        # @return [Hash{Symbol => String}] each bound field name mapped to
        #   its own source text
        def appended(bindings)
          bindings.to_h { |binding| [text(binding[:field]).to_sym, text(binding[:source])] }
        end

        # Classifies a single-binding mutation's own source.
        #
        # @param binding [Hash{Symbol => Object}] one dispatched binding row
        # @return [Hash{Symbol => Object}] `{kind: "argument"|"state",
        #   name: String}` for an argument or state reference, or
        #   `{kind: "literal", value: Object}` (the decoded literal) for
        #   anything else
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
