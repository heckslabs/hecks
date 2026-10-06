module Hecks
  module Bluebook
    module MetaValidator
      module Readings
        # Reads single fields off a node: a Declare payload field, a setter's source, the
        # target a reference points at, and the literal encoding a default rides in.
        module Fields
          def declared_name(node) = node.hecks_name

          # Reads one Declare payload field off `node`, using
          # Assembly::Contracts to find fields whose location differs from
          # their name rather than branching per category.
          def field_value(category, node, field, parent_id)
            return declared_name(node) if field == :name

            contract = Assembly.contract(category)
            # A setter names its target as a string; Declare fields arrive as
            # symbols, so the lookup key is normalized to a symbol either way.
            named    = field.to_sym
            return parent_id if contract.kind_of(named) == :parent

            object, member = contract.folded(named)
            return through(node, object, member) if member

            plain_field(category, node, field)
          end

          # The fields that read straight off the node, apart from the two the contract folds.
          def plain_field(category, node, field)
            # `limit` is an IR object, not a scalar, so its value is unwrapped.
            return node.limit&.to_h&.fetch(:value, nil) if "#{category}.#{field}" == "Query.limit"

            # Encoded so the hash literal doesn't get spelled through Ruby's
            # own to_s, which is not stable across Ruby versions.
            return encode_literal(node.provenance) if field == :provenance

            node.respond_to?(field) ? node.public_send(field) : nil
          end

          # Reads via `to_h` because the member names are the ones the IR
          # spells (a Lifecycle's `default`, an OrderBy's `direction`).
          def through(node, object, member)
            held = node.respond_to?(object) ? node.public_send(object) : nil
            return nil unless held

            member == :transitions ? held : held.to_h[member]
          end

          def setter_value(category, node, target)
            # `rows` folds into `closed_set` and `members` with no single
            # member to name, so it keeps its own reader.
            return closed_set_size(node) if "#{category}.#{target}" == "ValueObject.rows"

            object, member = Assembly.contract(category).folded(target.to_sym)
            return through(node, object, member) if member

            node.respond_to?(target) ? node.public_send(target) : nil
          end

          # `nil` for "not a closed set" keeps that distinct from an empty one.
          def closed_set_size(node)
            return nil unless node.respond_to?(:closed_set?) && node.closed_set?

            Array(node.members).size
          end

          # `Reference<Customer>` is an IR encoding; the language is offered
          # the target head's own id instead, and resolution does the rest.
          def points_at(row, aggregate_id)
            return nil unless row.reference?

            # Built the same way an aggregate id itself is built (chapter +
            # name), because `repository.find` resolves against that same id.
            Naming.identity([aggregate_id.split(Naming::IDENTITY_JOIN).first, row.type.target_name])
          end

          # Self-describing so the type survives the round trip (bare `to_s`
          # can't tell 0.0 from a string); `nil` stays `nil`, a real answer.
          def encode_literal(value) = value.nil? ? nil : Literal.render(value)

          # The inverse of `points_at`: strips the id's chapter prefix, joined
          # with `Naming::IDENTITY_JOIN` rather than the wire format's `::`.
          def reference_type(points_at_id) = "Reference<#{points_at_id.to_s.split(Naming::IDENTITY_JOIN).last}>"

          def row_value(row, field)
            # Hash responds to `key` and `value` too, so a Hash must be
            # checked for before respond_to?, not after.
            return row[field] if row.is_a?(Hash)
            return row.public_send(field) if row.respond_to?(field)
            # A Struct raises for a member it lacks, so it's read via to_h
            # instead — an absent field simply reads as absent.
            return row.to_h[field] if row.respond_to?(:to_h) && !row.is_a?(String)

            row
          end
        end
      end
    end
  end
end
