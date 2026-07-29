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
            # THE LANGUAGE DOES NOT HOLD THIS. Aggregate's Field value object carries
            # name, type and list — no default — so an aggregate attribute declared
            # `default:` loses it. Named in spec/round_trip_spec as a gap rather than
            # papered over; the fix is a field on Field, and the walk already has the
            # value to offer.
            default: nil
          }
        end

        def shape_field(field)
          {
            name:    text(field[:name])&.to_sym,
            type:    text(field[:type]),
            list:    text(field[:list]).to_s == "true",
            default: blank_to_nil(text(field[:default]))
          }
        end

        # ABSENT is not EMPTY, on the way back as much as on the way in: a default
        # never declared arrives as an empty cell and has to go back out as nil.
        def blank_to_nil(value) = value.to_s.empty? ? nil : value

        def rule(row) = { description: text(row[:description]), canonical: text(row[:canonical]) }

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

          kind == "argument" ? { kind: kind, name: value } : { kind: "literal", value: value }
        end
      end
    end
  end
end
