module Hecks
  module Bluebook
    module MetaValidator
      module Shapes
        # The small readings `Shapes` builds on: typed text, flags, blank text and option bindings.
        module Helpers
          # The fields an attribute row carries whatever its type reads back as.
          #
          # `optional` is read back the same way `list` is — both are booleans about the attribute,
          # held as text, and dropping either would rebuild a bluebook that says something other
          # than what was written. `admits` and `relationship` have only the round trip to come
          # in by: the grammar registry keeps the assembled graph, so a fact dropped here is a
          # fact no projection downstream ever sees, however plainly the .bluebook declares it.
          def attribute_row(field, type)
            {
              name:     text(field[:name])&.to_sym,
              type:     type,
              list:     flag?(field, :list),
              default:  decode_literal(text(field[:default])),
              optional: flag?(field, :optional)
            }.merge(attribute_texts(field))
          end

          # @return [Hash{Symbol => String, nil}] the pattern and closed-set facts, `nil` when blank
          def attribute_texts(field)
            { pattern: presence(text(field[:pattern])), admits: presence(text(field[:admits])),
              relationship: presence(text(field[:relationship])) }
          end

          # A flag held as text ("true"/"false"), read as a boolean.
          def flag?(field, key) = text(field[key]).to_s == "true"

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

          # "" is a real regex (matches everything) — kept as-is it would silently
          # turn "no pattern" into "always matches", so it is coerced to nil here.
          def presence(text)
            value = text.to_s
            value.empty? ? nil : value
          end

          # The self-describing form `Readings#encode_literal` wrote — the same
          # reader `Assembly::Marks` uses, for the identical spelling.
          def decode_literal(text) = Literal.read(text)

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
            return binding_of(single) if repeated.empty?

            repeated.group_by { |part| text(part[:at]) }.values.map { |group| binding_of(group) }
          end

          # @return [Hash{Symbol => Object}] one option binding, key to value
          def binding_of(parts) = parts.to_h { |part| [text(part[:key]).to_sym, text(part[:value])] }
        end
      end
    end
  end
end
