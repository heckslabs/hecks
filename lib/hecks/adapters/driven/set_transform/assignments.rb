module Hecks
  module Adapters
    module SetTransform
      # Compiles a statement's writes, its `SET` list, and the lifecycle conditions they bring:
      # each assignment as its field is stored, and a lifecycle transition as a `CASE` over the
      # states it moves from.
      module Assignments
        private

        # @return [Array(Array<String>, Array<String>)] the assignments and the filter conditions
        #   the lifecycle adds
        def set_list(statement, build)
          sets = statement.assignments.map { |assignment| assignment_sql(assignment, build) }
          lifecycle_sets, conditions = lifecycle_moves(statement, build)
          [sets + lifecycle_sets + version_bump, conditions]
        end

        # The lifecycle's assignment and the filter conditions its transition and `from:` guard add.
        def lifecycle_moves(statement, build)
          sets = []
          conditions = []
          if statement.transition
            case_sql, condition = transition_sql(statement.transition, build)
            sets << "#{quote_ident(@aggregate.lifecycle_field)} = #{case_sql}"
            conditions << condition
          end
          conditions << state_in(statement.from_guard, build) if statement.from_guard
          [sets, conditions]
        end

        def assignment_sql(assignment, build)
          field = writable_field(assignment.target)
          "#{quote_ident(field.name)} = #{assigned_value(field, assignment, build)}"
        end

        def assigned_value(field, assignment, build)
          case assignment.kind
          when :constant then constant_sql(field, assignment.value, build)
          when :copy then copied_sql(field, assignment.value)
          when :expression then expression_write(field, value_sql(assignment.value, build, strict: true), build)
          when :step then stepped_sql(field, assignment.value, build)
          else raise Uncompilable, "#{dialect_name} has no set-transform form for a #{assignment.kind} write"
          end
        end

        # A constant is encoded once by this store's own codec, so every row holds what a save
        # of that value would have written.
        def constant_sql(field, value, build)
          encoded = encode(@aggregate.attribute(field.name), value)
          encoded.nil? ? "NULL" : typed_placeholder(build.binds, encoded, :json)
        end

        def copied_sql(field, source)
          same_shape = @aggregate.attribute(source)&.type == @aggregate.attribute(field.name).type
          raise Uncompilable, "#{dialect_name} copies a field only from one of the same type" unless same_shape

          quote_ident(source)
        end

        def expression_write(field, operand, build)
          raise Uncompilable, "#{field.name} holds #{field.type}, not #{operand.type}" unless operand.type == field.type

          build.guards << "#{operand.sql} IS NOT NULL"
          scalar_write(field.member, operand.sql)
        end

        def stepped_sql(field, amount, build)
          raise Uncompilable, "#{dialect_name} steps only an Integer field" unless field.type == :integer

          current = scalar_read(field.name, field.member, field.type)
          build.guards << "#{current} IS NOT NULL"
          sum = "(#{current} + #{typed_placeholder(build.binds, amount, :integer)})"
          guard = integer_guard(sum)
          build.guards << guard if guard
          scalar_write(field.member, sum)
        end

        def writable_field(name)
          field = Runtime::ScalarField.of(@aggregate, name)
          return field if field&.writable?

          raise Uncompilable, "#{dialect_name} writes #{name} only through a dispatch"
        end

        # Each case in order: the first whose states hold the current one, or that names none.
        def transition_sql(cases, build)
          conditions = cases.map { |from, _| from ? state_in(from, build) : "TRUE" }
          whens = conditions.zip(cases).map do |condition, (_, target)|
            "WHEN #{condition} THEN #{typed_placeholder(build.binds, target.to_s, :string)}"
          end
          ["CASE #{whens.join(" ")} END", "(#{conditions.join(" OR ")})"]
        end

        def state_in(states, build)
          slots = Array(states).map { |state| typed_placeholder(build.binds, state.to_s, :string) }
          "(COALESCE(#{quote_ident(@aggregate.lifecycle_field)}, '') IN (#{slots.join(", ")}))"
        end
      end
    end
  end
end
