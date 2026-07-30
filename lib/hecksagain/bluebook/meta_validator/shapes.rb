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
            type: type.start_with?("#{aggregate_id}.") ? type.delete_prefix("#{aggregate_id}.") : reference_type(type),
            list: text(field[:list]).to_s == "true",
            default: decode_literal(text(field[:default]))
          }
        end

        def shape_field(field)
          {
            name:    text(field[:name])&.to_sym,
            type:    text(field[:type]),
            list:    text(field[:list]).to_s == "true",
            default: decode_literal(text(field[:default]))
          }
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
        # out, never called.
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
