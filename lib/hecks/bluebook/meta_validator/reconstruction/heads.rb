module Hecks
  module Bluebook
    module MetaValidator
      class Reconstruction
        # Rebuilds the heads of a chapter: an aggregate, its value objects and the entities
        # nested under it, each with its own commands and asks.
        module Heads
          private

          def aggregate(row)
            id = row[:id]

            aggregate_fields(row, id).merge(
              value_objects: declared("ValueObject", id).map { |shape| value_object(shape) },
              commands:      own("Command", id).map { |verb| command(verb) },
              entities:      direct_entities(id, id).map { |piece| entity(piece) },
              queries:       own("Query", id).map { |ask| query(ask) }
            )
          end

          # What an aggregate row holds on its own. Read by hand, not via `declaration()`, since
          # `aggregate` builds its hash directly; `rule` is the same reader `command`'s own uses.
          def aggregate_fields(row, id)
            {
              name:          text(row[:name]),
              description:   text(row[:description]),
              identified_by: identity_paths(row),
              attributes:    Array(row[:attributes]).map { |field| attribute(field, id) }
            }.merge(aggregate_rules(row)).merge(lifecycle: lifecycle(row), provenance: provenance(row))
          end

          # The rules and projected fields an aggregate row holds.
          def aggregate_rules(row)
            {
              invariants:       rules_in(row, :invariants),
              preconditions:    rules_in(row, :preconditions),
              projected_fields: Array(row[:projected_fields]).map { |held| projected_field(held) }
            }
          end

          def value_object(row) = declaration("ValueObject", row)

          def command(row) = declaration("Command", row)

          def query(row) = declaration("Query", row).merge(options_of(row))

          # Every entity sharing one root aggregate; `owner` (not the root id) tells
          # a direct entity apart from one nested further in.
          def direct_entities(root_id, owner_id)
            declared("Entity", root_id).select { |held| text(held[:owner]).to_s == owner_id.to_s }
          end

          def entity(row)
            entity_fields(row).merge(
              commands: within("Command", row).map { |verb| command(verb) },
              queries:  within("Query", row).map { |ask| query(ask) },
              entities: direct_entities(text(row[:aggregate]), row[:id]).map { |piece| entity(piece) }
            )
          end

          def entity_fields(row)
            {
              name:          text(row[:name]),
              description:   text(row[:description]),
              identified_by: identity_paths(row),
              attributes:    Array(row[:attributes]).map { |field| shape_field(field, text(row[:aggregate])) },
              preconditions: rules_in(row, :preconditions),
              invariants:    rules_in(row, :invariants),
              lifecycle:     lifecycle(row)
            }
          end

          # Assembled from three fields, because the IR keeps one object where the
          # language keeps the parts.
          def lifecycle(row)
            field = text(row[:state_field])
            return nil if field.to_s.empty?

            {
              field:       field,
              default:     text(row[:state_start]),
              transitions: Array(row[:transitions]).map { |move| transition(move) },
              marks:       Array(row[:marks]).map { |held| mark(held) }
            }
          end
        end
      end
    end
  end
end
