module Hecksagain
  module Bluebook
    class Assembly
      # One head, built from its declaration — and PROJECTED into a Ruby class.
      #
      # The fields come from the contract like every other construct's. What is here
      # is the part no field table can say: which construct holds which, and how a
      # head becomes a class with `create_pizza` on it, `Price` nested inside it, and
      # its references able to resolve.
      #
      # It DECIDES NOTHING. Whether a declaration is admissible was settled on the
      # way in, by the language.
      class AggregateAssembly
        def initialize(row)
          @row   = row
          @klass = Class.new(Aggregate)
          @klass.hecks_name = row[:name].to_s
        end

        def aggregate
          shapes   = Array(@row[:value_objects]).map { |shape| value_object(shape) }
          commands = Array(@row[:commands]).map { |verb| Build.call("Command", verb) }
          entities = Array(@row[:entities]).map { |piece| entity(piece) }
          asks     = Array(@row[:queries]).map { |ask| Build.call("Query", ask) }

          nest(shapes)
          [commands, entities, asks].each { |held| held.each { |one| one.hecks_owner = @klass } }

          ir = Build.call(
            "Aggregate", @row,
            value_objects: shapes,
            commands:      commands,
            entities:      entities,
            queries:       asks,
            lifecycle:     lifecycle_of(@row),
            policies:      [],
            reference_targets: commands.filter_map(&:references)
          )

          @klass.ir     = ir
          ir.ruby_class = @klass
          declare_surface(ir)
          stamp_references(ir)
          ir
        end

        private

        def value_object(row)
          Build.call("ValueObject", row)
        end

        def entity(row)
          Build.call(
            "Entity", row,
            commands:  Array(row[:commands]).map { |verb| Build.call("Command", verb) },
            queries:   Array(row[:queries]).map { |ask| Build.call("Query", ask) },
            lifecycle: lifecycle_of(row)
          )
        end

        # `Pizzas::Pizza::Price` — nested where the bluebook nests it, which is what
        # lets two heads each declare their own `Money`.
        def nest(shapes)
          shapes.each do |shape|
            shape.hecks_owner = @klass
            name = shape.hecks_name
            @klass.send(:remove_const, name) if @klass.const_defined?(name, false)
            @klass.const_set(name, shape)
          end
        end

        def declare_surface(ir)
          ir.attributes.each { |field| @klass.declare_reader(field.name) }
          @klass.declare_reader(ir.lifecycle.field) if ir.lifecycle
          ir.commands.each { |verb| @klass.declare_verb(verb.hecks_name, creates: verb.creates?) }
        end

        # Every reference learns which head declares it, so it can reach the chapter
        # and resolve. Deliberately across every list that can carry one — a
        # reference the walk misses resolves to nil, and a nil target is SKIPPED
        # rather than refused, so the guarantee would go quiet instead of red.
        def stamp_references(ir)
          lists = [ir.attributes, *ir.commands.map(&:attributes), *ir.queries.map(&:attributes)]
          ir.entities.each do |piece|
            lists << piece.attributes
            lists.concat(piece.commands.map(&:attributes))
            lists.concat(piece.queries.map(&:attributes))
          end

          lists.flatten.select(&:reference?).each { |field| field.type.declared_in = @klass }
        end

        # THREE LANGUAGE FIELDS, ONE IR OBJECT. `state_field`, `state_start` and
        # `transitions` are separate declarations; the IR keeps one Lifecycle. The
        # contract names them derived, and this is what derives them.
        def lifecycle_of(row)
          declared = row[:lifecycle]
          return nil unless declared

          IR::Lifecycle.new(
            field:       declared[:field],
            default:     declared[:default],
            transitions: transitions(Array(declared[:transitions]))
          )
        end

        # A lifecycle holds [command, StateTransition] pairs and `to_h` expands one
        # pair whose `from` is a list into several rows. Grouped back by command AND
        # TARGET, because one declared pair has exactly one target and may have many
        # froms — grouping by command alone would fuse two declarations that move the
        # same verb to different states.
        def transitions(rows)
          rows.group_by { |move| [move[:command], move[:to_state]] }
              .map do |(command, target), moves|
                froms = moves.filter_map { |move| move[:from_state] }
                [command.to_s, IR::StateTransition.new(target: target, from: from_of(froms))]
              end
        end

        def from_of(froms)
          return nil         if froms.empty?
          return froms.first if froms.size == 1

          froms
        end
      end
    end
  end
end
