module Hecksagain
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
        def attribute(field, aggregate_id)
          type = text(field[:type]).to_s

          {
            name: text(field[:name])&.to_sym,
            type: owned_type(type, aggregate_id) || reference_type(type),
            list: text(field[:list]).to_s == "true",
            default: decode_literal(text(field[:default])),
            # Read back the same way `list` is — both are booleans about the
            # attribute, held as text, and dropping either would rebuild a
            # bluebook that no longer says what it said.
            optional: text(field[:optional]).to_s == "true",
            pattern: presence(text(field[:pattern])),
            # THE ROUND TRIP IS THE ONLY WAY IN. The grammar registry keeps the
            # ASSEMBLED graph — the language as its own judge read it back — so a
            # fact dropped here is a fact no downstream projection ever sees, no
            # matter how plainly the .bluebook file declares it.
            admits: presence(text(field[:admits]))
          }
        end

        # A TYPE THIS AGGREGATE OWNS, offered as its id and read back as its name.
        # Prefixed with the owner and the identity join, because that IS the value
        # object's identity — the aggregate it belongs to, then its name.
        def owned_type(type, aggregate_id)
          prefix = Naming.identity([aggregate_id, ""])
          return nil unless type.start_with?(prefix)

          type.delete_prefix(prefix)
        end

        # ONE PART OF AN IDENTITY, read back as the path it went in as. The inverse
        # of `Marks#identity_path`, and named the same so the two directions read
        # as one table.
        def identity_path(part) = text(part[:value]).to_s

        # An argument, a parameter, a piece's attribute — the three places an
        # attribute is written that carry no owner id to strip.
        #
        # A REFERENCE among them came in as the head's ID, because that is what
        # Command/Entity/Query.Reference offer, so it goes back out as the
        # encoding the IR spells. A qualified name is the tell : an ordinary
        # type names something declared beside it (`Money`, `AccountNumber`) and
        # never carries a chapter, while a head's id always does.
        def shape_field(field)
          type = text(field[:type]).to_s

          {
            name:     text(field[:name])&.to_sym,
            # A QUALIFIED name is the tell : an ordinary type names something
            # declared beside it (`Money`, `AccountNumber`) and carries no join at
            # all, where a head's id always does (chapter + name, joined the way
            # every derived id is).
            type:     type.include?(Naming::IDENTITY_JOIN) ? reference_type(type) : text(field[:type]),
            list:     text(field[:list]).to_s == "true",
            default:  decode_literal(text(field[:default])),
            optional: text(field[:optional]).to_s == "true",
            pattern:  presence(text(field[:pattern])),
            admits:   presence(text(field[:admits]))
          }
        end

        # An ABSENT pattern is nil, not "". The language holds every field as
        # text, so a field nobody set comes back as the empty string — and ""
        # is a real regex (it matches everything), so keeping it would turn
        # "no pattern" into "a pattern that always passes" and quietly cost the
        # IR its round trip.
        def presence(text)
          value = text.to_s
          value.empty? ? nil : value
        end

        # A literal, read back from the self-describing form Readings#encode_literal
        # wrote. The forms are exactly the five the Primitive vocabulary admits —
        # String, Integer, Float, TrueClass, FalseClass — plus a symbol, and a flat
        # object literal, which is what `to: { value: "good" }` is: a value object's
        # fields written inline.
        def decode_literal(text)
          raw = text.to_s
          return nil if raw.empty?
          return decode_object(raw)      if raw.start_with?("{") && raw.end_with?("}")
          return raw[1..-2]              if raw.start_with?('"') && raw.end_with?('"')
          return raw[1..].to_sym         if raw.start_with?(":")
          return true                    if raw == "true"
          return false                   if raw == "false"
          return raw.to_i                if raw.match?(/\A-?\d+\z/)
          return raw.to_f                if raw.match?(/\A-?\d+\.\d+\z/)

          raw
        end

        # Scanned rather than split on ", ", so a quoted value carrying a comma does
        # not tear in half.
        def decode_object(raw)
          raw.scan(/:(\w+)=>("[^"]*"|[^,}]+)/).to_h do |key, value|
            [key.to_sym, decode_literal(value.strip)]
          end
        end

        def rule(row) = { description: text(row[:description]), canonical: text(row[:canonical]) }

        # `provenance from: {...}` rides the same literal encoding `default:`
        # does — a flat object literal, self-describing via `inspect` — one
        # level up: a whole keyword's argument rather than an attribute's
        # `default:`.
        def provenance(row) = decode_literal(text(row[:provenance]))

        # THE OPTION ROWS, GATHERED BACK into the shapes `extra_options_to_h` spells.
        #
        # One row per part, so a compound option is several rows and a repeated one is
        # several groups told apart by `at`. Grouping by option name and then by `at`
        # rebuilds both without either knowing which options exist — the whole point
        # of holding them as an open map.
        def options_of(row)
          Array(row[:options])
            .group_by { |part| text(part[:option]) }
            .to_h { |option, parts| [option.to_sym, gathered(parts)] }
        end

        def gathered(parts)
          repeated, single = parts.partition { |part| !text(part[:at]).to_s.empty? }
          return single.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] } if repeated.empty?

          repeated.group_by { |part| text(part[:at]) }
                  .values
                  .map { |group| group.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] } }
        end

        # The IR keeps a where's field as a STRING, not a symbol — it is read back
        # out, never called. The value stays RAW TEXT here on purpose : this
        # feeds the declaration hash Assembly::Marks#where_clause decodes
        # from (via `unmark`), and decoding twice is worse than once — a
        # kwarg reference (":ceiling") decoded here into the Symbol :ceiling
        # would have its colon stripped by `unmark`'s own `.to_s` and come
        # back out as the plain string "ceiling", indistinguishable from a
        # literal of the same name. One decode, at the one place that builds
        # the object every comparator actually reads.
        def where_clause(row)
          { field: text(row[:field]), op: text(row[:op]), value: text(row[:value]) }
        end

        # One object in the IR, two fields in the language.
        def order_by(row)
          field = text(row[:order_field])
          return nil if field.to_s.empty?

          { field: field, direction: text(row[:order_way]) }
        end

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
            # A String, like an entity's identified_by. The IR is not uniform about
            # this and only a round trip says so.
            as:        text(row[:as]),
            many:      text(row[:many]).to_s == "true"
          }
        end

        # THE APPEND FLATTENING, IN REVERSE.
        #
        # An append binds several fields at once and the language's Change holds one
        # field/kind/source triple, so the walk offers an append once PER BINDING.
        # Rebuilding groups those rows back into the single mutation the IR keeps —
        # the only place here that undoes something rather than simply reading it.
        def mutations(row)
          Array(row[:mutations])
            .group_by { |change| [text(change[:target]), text(change[:op])] }
            .map { |(target, op), bindings| mutation(target, op, bindings) }
        end

        def mutation(target, op, bindings)
          base = { target: target.to_sym, op: op.to_sym }
          return base.merge(fields: appended(bindings)) if op == "append"

          base.merge(source: classified(bindings.first))
        end

        def appended(bindings)
          bindings.to_h { |binding| [text(binding[:field]).to_sym, text(binding[:source])] }
        end

        def classified(binding)
          kind  = text(binding[:kind])
          value = text(binding[:source])

          return { kind: kind, name: value } if kind == "argument"

          { kind: "literal", value: decode_literal(value) }
        end
      end
    end
  end
end
