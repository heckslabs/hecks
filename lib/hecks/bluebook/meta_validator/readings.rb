module Hecks
  module Bluebook
    module MetaValidator
      # Reads the parts of a bluebook IR whose shape differs from the
      # language's own, for the meta validator's walk.
      module Readings
        # Looks up a per-category shaper (Assembly::Contracts) instead of
        # switching on category here; a list with no shaper reads straight
        # off the node.
        def rows_for(category, list_name, node)
          shaper = Assembly.contract(category).shaper(list_name)
          return Array(node.public_send(list_name)) unless shaper

          public_send(shaper, node)
        end

        # Reads through `to_h`, where the IR spells a symbol argument as
        # `:ceiling`; reading the object directly loses the colon.
        def where_rows(node) = Array(node.wheres).map(&:to_h)

        # The IR holds the value object itself; the language wants only its name.
        def value_object_names(node) = node.value_objects.map { |shape| { name: shape.hecks_name } }

        # One row per identity path part, in order — the join between them
        # is the whole meaning of the identity.
        def identity_rows(node) = node.identity_paths.map { |path| { value: path } }

        # Reads through `to_h`, where `Bluebook.render_value` spells a symbol
        # argument as `:source`.
        def with_spec_rows(node) = pair_rows(node.to_h[:with_spec])

        # `compensates` nests its own with_spec one hash down; `&.dig` makes
        # "no compensation" `pair_rows(nil)`, i.e. empty, not an error.
        def compensates_with_spec_rows(node) = pair_rows(node.to_h[:compensates]&.dig(:with_spec))

        def read_model_option_rows(node) = option_rows(node, filters: true)

        # The canonical-form table belongs to the expression grammar, not to
        # any one node, so the node itself is unused.
        def normalisation_table(_node) = normalisation_rows

        # One `lifecycle` declaration can list several `from` states, so it
        # expands into one row per state (or one unconstrained row).
        def transition_rows(node)
          lifecycle = node.respond_to?(:lifecycle) ? node.lifecycle : nil
          return [] unless lifecycle

          lifecycle.transitions.flat_map do |command, transition|
            froms = transition.constrained? ? Array(transition.from) : [nil]
            froms.map do |from|
              { command: command, from_state: from, to_state: transition.target }
            end
          end
        end

        # An open map has no value object to hold it, so each entry is its own row.
        def pair_rows(map)
          Array(map&.to_h).map { |key, value| { key: key, value: value } }
        end

        # Flattens options via `extra_options_to_h` — a new option needs no
        # change here. `filters: true` reads wheres/order_by/limit live off
        # the node, not `to_h`, so wire-format changes there don't affect it.
        def option_rows(node, filters: false)
          return [] unless node.respond_to?(:extra_options_to_h)

          spelled = node.extra_options_to_h
          spelled = filter_options(node).merge(spelled) if filters

          spelled.flat_map do |option, held|
            case held
            when Array then held.each_with_index.flat_map { |one, at| parts(option, one, at) }
            else parts(option, held, nil)
            end
          end
        end

        # Named to match the declaration keys the assembly already reads.
        def filter_options(node)
          {
            wheres:   Array(node.wheres).map(&:to_h),
            order_by: node.order_by&.to_h,
            limit:    node.limit&.to_h
          }.reject { |_, held| held.nil? || held == [] }
        end

        def parts(option, held, at)
          Hash(held).map do |key, value|
            { option: option.to_s, key: key.to_s, value: value, at: at&.to_s }
          end
        end

        # append/delegate/corrects bind several fields at once, so each
        # binding is its own row; set/increment/decrement get a single row.
        def mutation_rows(node)
          Array(node.mutations).flat_map do |mutation|
            # delegate/corrects ride the same multi-binding shape append does.
            next set_row(mutation) unless [:append, :delegate, :corrects].include?(mutation.op)

            mutation.source.map do |field, argument|
              # Spelled as Mutation#appended_fields spells it; Assembly::Marks
              # reads this row back through the same reader.
              { target: mutation.target, op: mutation.op, field: field,
                kind: argument.is_a?(Symbol) ? "argument" : "literal",
                source: Literal.render(argument) }
            end
          end
        end

        def set_row(mutation)
          classified = mutation.to_h[:source] || {}

          [{ target: mutation.target, op: mutation.op, field: mutation.target,
             kind: classified[:kind],
             source: classified[:name] || encode_literal(classified[:value]) }]
        end

        # The table belongs to the expression grammar, not to any one
        # bluebook.
        def normalisation_rows
          table = Expression::CanonicalForm.table
          return [] unless table

          table.map do |entry|
            {
              strategy:     entry[:strategy],
              source_token: entry[:source_token],
              replacement:  entry[:replacement],
              boundary:     entry[:boundary],
              position:     entry[:position]
            }
          end
        rescue StandardError
          # A bluebook that cannot produce this table is not malformed.
          []
        end

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
