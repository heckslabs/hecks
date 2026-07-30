module Hecksagain
  module Bluebook
    class Assembly
      # One head, built from its declaration.
      #
      # The mirror of `AggregateBuilder#build`, with the DSL taken out: instead of
      # collecting declarations as a block is evaluated, it reads them from a hash.
      # Everything after that is identical, and deliberately so — the class, the
      # nested value objects, the verbs defined on it, the owners, the references
      # stamped once every sibling exists.
      #
      # It DECIDES NOTHING. Whether a declaration is admissible was settled on the
      # way in, by the language.
      class AggregateAssembly
        include Marks

        def initialize(row)
          @row   = row
          @klass = Class.new(Aggregate)
          @klass.hecks_name = row[:name].to_s
        end

        def aggregate
          shapes    = Array(@row[:value_objects]).map { |shape| value_object(shape) }
          entities  = Array(@row[:entities]).map { |piece| entity(piece) }
          commands  = Array(@row[:commands]).map { |verb| command(verb) }
          asks      = Array(@row[:queries]).map { |ask| query(ask) }
          fields    = Array(@row[:attributes]).map { |field| attribute(field) }

          nest(shapes)
          commands.each { |verb| verb.hecks_owner = @klass }
          entities.each { |piece| piece.hecks_owner = @klass }
          asks.each { |ask| ask.hecks_owner = @klass }

          ir = IR::Aggregate.new(
            name:          @row[:name],
            description:   @row[:description],
            attributes:    fields,
            value_objects: shapes,
            commands:      commands,
            identified_by: @row[:identified_by] || :id,
            lifecycle:     lifecycle,
            entities:      entities,
            queries:       asks,
            policies:      [],
            reference_targets: commands.filter_map(&:references)
          )

          @klass.ir     = ir
          ir.ruby_class = @klass
          declare_surface(fields, commands)
          stamp_references(ir)
          ir
        end

        private

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

        def declare_surface(fields, commands)
          fields.each { |field| @klass.declare_reader(field.name) }
          @klass.declare_reader(@row.dig(:lifecycle, :field)) if @row[:lifecycle]
          commands.each { |verb| @klass.declare_verb(verb.hecks_name, creates: verb.creates?) }
        end

        # Every reference learns which head declares it, so it can reach the chapter
        # and resolve. Deliberately across every list that can carry one — a
        # reference the walk misses resolves to nil, and a nil target is SKIPPED
        # rather than refused.
        def stamp_references(ir)
          lists = [ir.attributes, *ir.commands.map(&:attributes), *ir.queries.map(&:attributes)]
          ir.entities.each do |piece|
            lists << piece.attributes
            lists.concat(piece.commands.map(&:attributes))
            lists.concat(piece.queries.map(&:attributes))
          end

          lists.flatten.select(&:reference?).each { |field| field.type.declared_in = @klass }
        end

        def value_object(row)
          IR::ValueObject.declare(
            name:       row[:name],
            attributes: Array(row[:attributes]).map { |field| shape_field(field) },
            invariants: Array(row[:invariants]).map { |rule| invariant(rule) },
            members:    Array(row[:members]).map { |member| member.to_h { |key, value| [key.to_sym, value] } },
            closed_set: row[:closed_set] ? true : false
          )
        end

        def command(row)
          IR::Command.declare(
            name:       row[:name],
            role:       row[:role],
            goal:       row[:goal],
            references: row[:references],
            attributes: Array(row[:attributes]).map { |field| shape_field(field) },
            givens:     Array(row[:givens]).map { |rule| given(rule) },
            mutations:  Array(row[:mutations]).map { |change| mutation(change) },
            emits:      Array(row[:emits])
          )
        end

        def entity(row)
          piece = IR::Entity.declare(
            name:          row[:name],
            description:   row[:description],
            identified_by: row[:identified_by],
            attributes:    Array(row[:attributes]).map { |field| shape_field(field) },
            commands:      Array(row[:commands]).map { |verb| command(verb) },
            queries:       Array(row[:queries]).map { |ask| query(ask) },
            lifecycle:     lifecycle_of(row)
          )
          piece
        end

        def query(row)
          IR::Query.new(
            name:        row[:name],
            description: row[:description],
            attributes:  Array(row[:attributes]).map { |field| shape_field(field) },
            wheres:      Array(row[:wheres]).map { |clause| where_clause(clause) },
            order_by:    order_by(row[:order_by]),
            limit:       limit(row[:limit])
          )
        end

        def lifecycle = lifecycle_of(@row)

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
          return nil     if froms.empty?
          return froms.first if froms.size == 1

          froms
        end
      end
    end
  end
end
