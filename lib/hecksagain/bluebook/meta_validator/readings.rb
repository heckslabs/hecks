module Hecksagain
  module Bluebook
    module MetaValidator
      # The parts of a bluebook the walk cannot read by name alone.
      #
      # The language now spells its fields exactly as the IR spells them, so the
      # judge reads almost everything straight through: `command.givens`,
      # `value_object.invariants`, `read_model.aggregate_heads`. What remains here
      # is not naming drift — it is places where the IR's SHAPE differs from the
      # language's, and no amount of renaming would close that:
      #
      #   transitions    one declaration expands to SEVERAL rows, because `from`
      #                  may be a list of states
      #   value_objects  the IR holds objects ; the language holds their names
      #   normalisations not on the bluebook at all — they come from the canonical
      #                  form table the expression grammar keeps
      #   members        plain hashes, one Member root per row, pairs per entry
      #   lifecycle      one IR object feeding two separate fields
      #
      # Everything in this file is a difference in shape. If something here is
      # only a difference in NAME, it is in the wrong file: rename the language.
      module Readings
        # A list the walk is about to offer, as rows it can shape into dispatches.
        def rows_for(category, list_name, node)
          case "#{category}.#{list_name}"
          when "Aggregate.transitions", "Entity.transitions" then transition_rows(node)
          when "Command.mutations"                           then mutation_rows(node)
          # A where-clause is read through its own to_h, which is where the IR
          # spells a symbol argument as ":ceiling". Reading the OBJECT instead lost
          # the colon, and nothing downstream could tell an argument from a literal
          # of the same name.
          when "Query.wheres"                                then Array(node.wheres).map(&:to_h)
          when "Aggregate.value_objects"                     then node.value_objects.map { |shape| { name: shape.hecks_name } }
          when "Bluebook.normalisations"                     then normalisation_rows
          when "Member.pairs"                                then pair_rows(node)
          # Through to_h, which is where IR.render_value spells a symbol argument as
          # ":source". The raw with_spec lost the colon, and a binding that reads an
          # argument became indistinguishable from one carrying a literal string.
          when "Dispatch.with_spec"                          then pair_rows(node.to_h[:with])
          else Array(node.public_send(list_name))
          end
        end

        # `lifecycle :status do transition "Retire" => "retired", from: ["issued", "active"] end`
        # is ONE declaration and TWO transitions. Offering it once would leave the
        # second unjudged, which is the whole failure this judge exists to avoid.
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

        # An OPEN MAP — a member's fields, a dispatch's argument bindings — has no
        # value object that can hold it, so each entry becomes its own row. This is
        # why Member and Dispatch are roots in the language rather than lists.
        def pair_rows(map)
          Array(map&.to_h).map { |key, value| { key: key, value: value } }
        end

        # A mutation is ONE declaration, but the language's Change holds a single
        # field/kind/source triple — and an append binds SEVERAL fields at once
        # (`append: { name: :name, amount: :amount }`). So an append is offered
        # once per binding, and each one is judged.
        #
        # The judge used to send `field: v(""), kind: v("argument"), source: v("")`
        # here — three stubbed values, so every rule about what a mutation reads
        # was being handed a blank and could never refuse.
        def mutation_rows(node)
          Array(node.mutations).flat_map do |mutation|
            next set_row(mutation) unless mutation.op == :append

            mutation.source.map do |field, argument|
              # Spelled the way IR::Mutation#appended_fields spells it: a symbol bare
              # because it names an argument, anything else inspected because it IS
              # the value. `then_set :marks, append: { direction: "out" }` binds a
              # LITERAL, and storing it raw made it indistinguishable from an
              # argument called out.
              { target: mutation.target, op: mutation.op, field: field,
                kind: argument.is_a?(Symbol) ? "argument" : "literal",
                source: argument.is_a?(Symbol) ? argument.to_s : encode_literal(argument) }
            end
          end
        end

        # A set/increment/decrement reads one thing: a command argument, or a
        # literal written into the bluebook.
        def set_row(mutation)
          classified = mutation.to_h[:source] || {}

          [{ target: mutation.target, op: mutation.op, field: mutation.target,
             kind: classified[:kind],
             source: classified[:name] || encode_literal(classified[:value]) }]
        end

        # The normalisation table belongs to the expression grammar, not to any one
        # bluebook — it is how the canonical form of a rule is spelled. The language
        # models it because a bluebook's rules are canonicalised on the way in.
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
          # The table is a convenience of the Ruby side ; a bluebook that cannot
          # produce one is not malformed.
          []
        end

        # What the BLUEBOOK calls a node, whichever kind of thing the node is.
        #
        # A construct that has become a Ruby class answers `name` with its
        # constant path — `Pizzas::Pizza::Price` — because that is Ruby's
        # question, not the bluebook's. Its declared name is `hecks_name`. Value
        # objects have crossed over and the other categories have not, so this
        # asks for the bluebook's name and takes whichever the node can give.
        #
        # This shrinks to `node.hecks_name` when every construct is a class, and
        # disappears when the DSL stops handing the judge nodes at all.
        def declared_name(node)
          node.respond_to?(:hecks_name) ? node.hecks_name : node.name
        end

        # One field of a Declare payload. Mostly a reader of the same name — the
        # exceptions are fields the IR keeps somewhere else, or not at all.
        def field_value(category, node, field, parent_id)
          return declared_name(node) if field == :name

          case "#{category}.#{field}"
          when "Entity.owner"       then parent_id
          when "Member.shape"       then parent_id
          when "Aggregate.state_field", "Entity.state_field"  then node.lifecycle&.field
          when "Aggregate.state_start", "Entity.state_start"  then node.lifecycle&.default
          # `Array(an_object)` wraps rather than destructures, so these were offering
          # the OrderBy object itself and storing its inspect string.
          # Same wrapping mistake as order_by: `limit` is an object, and offering it
          # stored "#<struct LimitSpec value=3>".
          when "Query.limit"        then node.limit&.to_h&.fetch(:value, nil)
          when "Query.order_field"  then node.order_by&.to_h&.fetch(:field, nil)
          when "Query.order_way"    then node.order_by&.to_h&.fetch(:direction, nil)
          else node.respond_to?(field) ? node.public_send(field) : nil
          end
        end

        # What a setting command writes. A setter whose source is absent is not
        # dispatched at all — ABSENT is not EMPTY, and offering "" would turn every
        # "if you declare it, declare something" rule into "you must declare it".
        def setter_value(category, node, target)
          case "#{category}.#{target}"
          when "ValueObject.rows"  then closed_set_size(node)
          when "Aggregate.state_field", "Entity.state_field"  then node.lifecycle&.field
          when "Aggregate.state_start", "Entity.state_start"  then node.lifecycle&.default
          else node.respond_to?(target) ? node.public_send(target) : nil
          end
        end

        # Only a DECLARED closed set has a row count. An empty one is the defect,
        # so `rows` must stay absent rather than arrive as zero.
        def closed_set_size(node)
          return nil unless node.respond_to?(:closed_set?) && node.closed_set?

          Array(node.members).size
        end

        # `Reference<Customer>` is an IR ENCODING, not a domain fact. The fact is
        # that the attribute points at Customer's head — so the language is offered
        # that head's ID, and resolution does the rest. Encoding and decoding both
        # live here, because this is where the IR's shape differs from the
        # language's and nowhere else should know the spelling.
        def points_at(row, aggregate_id)
          return nil unless row.reference?

          "#{aggregate_id.split('::').first}::#{row.type.target_name}"
        end

        # A LITERAL, written so it can be read back exactly.
        #
        # The language holds a default and a literal mutation source as text, and
        # `to_s` threw the type away: 0.0 came back "0.0", and `{ value: "good" }`
        # came back its inspect string with nowhere to say it had been a hash. The
        # language already stores code as text — `canonical: "cents >= 0"` — so an
        # encoding is in keeping; it simply has to be SELF-DESCRIBING. `inspect` is:
        # a number is bare, a string is quoted, a symbol wears its colon, an object
        # wears its braces. Shapes#decode_literal reads it back.
        def encode_literal(value) = value.nil? ? nil : value.inspect

        # The way back out: an aggregate id becomes the type the IR spells.
        def reference_type(points_at_id) = "Reference<#{points_at_id.to_s.split('::').last}>"

        # One value out of a row, named by the value object's field.
        def row_value(row, field)
          # A Hash FIRST. Hash answers to `key` (Hash#key(value)) and to `value` on
          # some rows, so asking respond_to? before checking for a Hash reads a
          # member pair through entirely the wrong method.
          return row[field] if row.is_a?(Hash)
          return row.public_send(field) if row.respond_to?(field)
          # A Struct answers to [] but RAISES for a member it does not have, so it
          # is read through to_h — a field the row simply lacks reads as absent.
          return row.to_h[field] if row.respond_to?(:to_h) && !row.is_a?(String)

          # A bare scalar row — `emits` is a list of event NAMES, and the
          # Announcement value object has to call that string something.
          row
        end
      end
    end
  end
end
