module Hecks
  module Bluebook
    module MetaValidator
      # The leaf shapes of a reconstructed bluebook: the small hashes at each tip of
      # the tree (attribute, rule, where-clause, transition), decoded from their wire form.
      module Shapes
        # The type came in as the id of what it names, so it goes back out as the
        # name — or, for another aggregate's head, as the encoding the IR spells.
        def attribute(field, aggregate_id)
          type = text(field[:type]).to_s

          {
            name:         text(field[:name])&.to_sym,
            type:         owned_type(type, aggregate_id) || sibling_type(type) || reference_type(type),
            list:         text(field[:list]).to_s == "true",
            default:      decode_literal(text(field[:default])),
            # Read back the same way `list` is — both are booleans about the
            # attribute, held as text, and dropping either would rebuild a
            # bluebook that says something other than what was written.
            optional:     text(field[:optional]).to_s == "true",
            pattern:      presence(text(field[:pattern])),
            # The round trip is the only way in: the grammar registry keeps the
            # assembled graph, so a fact dropped here is a fact no projection
            # downstream ever sees, however plainly the .bluebook declares it.
            admits:       presence(text(field[:admits])),
            relationship: presence(text(field[:relationship]))
          }
        end

        # A type this aggregate owns, offered on the wire as its id.
        # Read back here as the bare name, stripping the owner/identity prefix.
        def owned_type(type, aggregate_id)
          prefix = Naming.identity([aggregate_id, ""])
          return nil unless type.start_with?(prefix)

          type.delete_prefix(prefix)
        end

        # A sibling aggregate's declared type, offered as its id; read back as the bare name.
        # A three-segment id names a declaration; a two-segment id is a Reference head instead.
        def sibling_type(type)
          segments = type.split(Naming::IDENTITY_JOIN)
          segments.last if segments.size == 3
        end

        # The inverse of `Marks#identity_path`, named the same so the two
        # directions read as one table.
        def identity_path(part) = text(part[:value]).to_s

        # An argument, a parameter, or (via `aggregate_id`) a piece's own attribute —
        # a piece's own attribute names a value object exactly the way an aggregate's
        # own does, so it takes the same owned-type reading `attribute`, above, does.
        def shape_field(field, aggregate_id = nil)
          return attribute(field, aggregate_id) if aggregate_id

          type = text(field[:type]).to_s

          {
            name:         text(field[:name])&.to_sym,
            # A qualified name is the tell: an ordinary type (`Money`, `AccountNumber`)
            # carries no join at all, while a head's id always does (chapter + name).
            type:         type.include?(Naming::IDENTITY_JOIN) ? reference_type(type) : text(field[:type]),
            list:         text(field[:list]).to_s == "true",
            default:      decode_literal(text(field[:default])),
            optional:     text(field[:optional]).to_s == "true",
            pattern:      presence(text(field[:pattern])),
            admits:       presence(text(field[:admits])),
            relationship: presence(text(field[:relationship]))
          }
        end

        # "" is a real regex (matches everything) — kept as-is it would silently
        # turn "no pattern" into "always matches", so it is coerced to nil here.
        def presence(text)
          value = text.to_s
          value.empty? ? nil : value
        end

        # The self-describing form `Readings#encode_literal` wrote — the same
        # reader `Assembly::Marks` uses, for the identical spelling.
        def decode_literal(text) = Literal.read(text)

        # A rule's plain description/canonical pair, for a `given`/`invariant`/`ensures`.
        def rule(row) = { description: text(row[:description]), canonical: text(row[:canonical]) }

        # One outside fact a command needs, in the shape `Command#to_h` emits it.
        def need(row) = { fact: text(row[:fact]) }

        # `projects :name, from: :"reference.remote_field"` (ADR 0025), read back as
        # its plain name/reference/remote_field triple.
        def projected_field(row)
          { name: text(row[:name]), reference: text(row[:reference]), remote_field: text(row[:remote_field]) }
        end

        # `provenance from: {...}` rides the same literal encoding `default:` does,
        # one level up: a whole keyword's argument rather than an attribute's.
        def provenance(row) = decode_literal(text(row[:provenance]))

        # `command "Debit", from: "open"` (ADR 0025) — the same literal encoding
        # `provenance`/`default:` ride, one state or an array of them, or nil.
        def from(row) = decode_literal(text(row[:from]))

        # A flag held as text ("true"/"false"), emitted as a boolean.
        def expect_undelivered?(row) = text(row[:expect_undelivered]).to_s == "true"

        # Regroups dispatched option rows into the shape `extra_options_to_h` spells:
        # one row per part, several `at`-keyed groups for a repeated option.
        def options_of(row)
          Array(row[:options])
            .group_by { |part| text(part[:option]) }
            .to_h { |option, parts| [option.to_sym, gathered(parts)] }
        end

        # One option's own parts, grouped back into a single binding — or several
        # `at`-keyed groups when the option repeats.
        def gathered(parts)
          repeated, single = parts.partition { |part| !text(part[:at]).to_s.empty? }
          return single.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] } if repeated.empty?

          repeated.group_by { |part| text(part[:at]) }
                  .values
                  .map { |group| group.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] } }
        end

        # Kept as raw text, not decoded: this feeds `Assembly::Marks#where_clause`,
        # which decodes it via `read` — decoding here first would strip a kwarg
        # reference's colon, indistinguishable after from a same-named literal.
        def where_clause(row)
          { field: text(row[:field]), op: text(row[:op]), value: text(row[:value]) }
        end

        # One object in the IR, two fields in the language.
        def order_by(row)
          field = text(row[:order_field])
          return nil if field.to_s.empty?

          { field: field, direction: text(row[:order_way]) }
        end

        # A read model's own declared row limit, or nil when none was declared.
        def limit(row)
          ceiling = text(row[:limit])
          return nil if ceiling.to_s.empty?

          { value: ceiling }
        end

        def transition(row)
          {
            command:    text(row[:command]),
            from_state: text(row[:from_state]),
            to_state:   text(row[:to_state])
          }
        end

        def head(row)
          {
            aggregate: text(row[:aggregate]),
            # A String, like an entity's identified_by. The IR is not uniform
            # about this and only a round trip says so.
            as:        text(row[:as]),
            many:      text(row[:many]).to_s == "true"
          }
        end

        def group_by_field(row) = { field: text(row[:field]) }

        # Mirrors `head`'s own `many`, but nil (never `false`) for an undeclared
        # read model — matching `ReadModel#to_h`'s own true/nil pairing.
        def read_model_count(row) = (true if text(row[:count]).to_s == "true")

        # `percentile_at` is stored as text (the self-hosted grammar's own
        # `ReadModelText`, ADR 0078), but the wire and `ReadModel#initialize`'s
        # own `&.to_f` both want a Float.
        def read_model_percentile_at(row) = text(row[:percentile_at])&.to_f

        # The append flattening, in reverse: regroups per-binding rows back
        # into one mutation per distinct target/op pair.
        def mutations(row)
          Array(row[:mutations])
            .group_by { |change| [text(change[:target]), text(change[:op])] }
            .map { |(target, op), bindings| mutation(target, op, bindings) }
        end

        # `sign:` is recomputed via `Mutation.sign_for`, not stored on any row —
        # Change carries no `sign` field of its own, so a fresh Mutation's `to_h`
        # derives it the same way here, rather than leaving the key silently absent.
        def mutation(target, oper, bindings)
          base = { target: target.to_sym, op: oper.to_sym, sign: Hecks::Bluebook::Mutation.sign_for(oper) }
          # `:delegate`/`:corrects` (CommandBuilder#delegates_to's and
          # #corrects_impl's own comments) ride the same multi-binding
          # shape `:append` does.
          return base.merge(fields: appended(bindings)) if ["append", "delegate", "corrects"].include?(oper)

          base.merge(source: classified(bindings.first))
        end

        # Rebuilds an append's own field -> source map from its flattened per-binding rows.
        def appended(bindings)
          bindings.to_h { |binding| [text(binding[:field]).to_sym, text(binding[:source])] }
        end

        # Classifies a single-binding mutation's own source: argument/state
        # reference, or a decoded literal.
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
