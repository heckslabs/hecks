require_relative "../../query_specification/field_path"
require_relative "../../runtime/value"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Query arguments drawn from rows the sequence has already written, so a
      # query can match a stored row instead of a fresh word that matches nothing.
      #
      # After each effective command, the compared fields of every aggregate a
      # query filters on are read back from the repository as one row per record.
      # The choice uses its own `Random` (`restart_random`); drawing from `@random`
      # would shift every later step of every seed.
      module QueryBinding
        # How often a query step takes its arguments from a written row; the
        # rest of the time the generated miss is kept.
        BOUND_QUERY_PROBABILITY = 0.75

        # Comparators taking one scalar operand; `in` and `none_in_state` do not.
        BINDABLE_OPERATORS = %i[eq ne lt lte gt gte].freeze

        # Keeps the binding stream apart from `@random`, which is seeded with the bare seed.
        BINDING_SEED_OFFSET = 0x9e3779b1

        private

        # `{"Domain::Aggregate" => {domain:, aggregate:, fields: [String]}}`
        # for every aggregate some query filters on, where `fields` is the
        # union of the stored fields those queries compare.
        def build_query_bindings(runtime)
          runtime.registry.bluebooks.each_with_object({}) do |(domain_name, bluebook), bindings|
            bluebook.aggregates.each do |aggregate|
              fields = aggregate.queries.flat_map { |query| bound_fields(query).values }.uniq
              next if fields.empty?

              bindings["#{domain_name}::#{aggregate.hecks_name}"] =
                { domain: domain_name, aggregate: aggregate, fields: fields }
            end
          end
        end

        # `{parameter name => stored field}` for each `where` clause whose
        # operand is one of the query's own parameters. A clause on a literal,
        # or aimed at another aggregate's field (`target`), binds nothing.
        def bound_fields(query)
          query.wheres.each_with_object({}) do |clause, fields|
            next unless clause.value.is_a?(Symbol) && clause.target.nil?
            next unless BINDABLE_OPERATORS.include?(clause.op.to_sym)

            fields[clause.value.to_s] ||= clause.field.to_s
          end
        end

        # Remembers the compared fields of every stored record of every
        # aggregate a query filters on, as one row per distinct record shape.
        def harvest_written_rows(runtime, catalog)
          catalog[:query_bindings].each do |key, binding|
            repository = runtime.registry.repository(binding[:domain], binding[:aggregate])
            repository.all.each { |record| remember_row(key, written_row(binding, record)) }
          end
        end

        def written_row(binding, record)
          binding[:fields].to_h { |field| [field, written_value(field_of(record, field))] }.compact
        end

        def remember_row(key, row)
          @written_rows[key] << row unless row.empty? || @written_rows[key].include?(row)
        end

        def field_of(record, field) = QuerySpecification::FieldPath.dig(record.state, field)

        # A stored value as the JSON-shaped argument a step carries: string
        # keys, nested values opened. `nil` for anything a query argument
        # cannot be (a missing value, a list, a timestamp object).
        def written_value(value)
          case value
          when Runtime::Value then written_value(value.to_h)
          when Hash           then value.to_h { |key, inner| [key.to_s, written_value(inner)] }
          when String, Integer, Float, true, false then value
          end
        end

        # Replaces the generated arguments of a query step with a remembered
        # row's, most of the time. Only a parameter the step already carries
        # is replaced, so an optional argument left out, or a required one a
        # malformation dropped, stays that way.
        def bind_to_written_row!(args, entry)
          return if entry[:entity]

          rows   = @written_rows[entry[:verb].split(".").first]
          params = bound_fields(entry[:query]).select { |param, _| args.key?(param) }
          return if rows.empty? || params.empty? || @binding_random.rand >= BOUND_QUERY_PROBABILITY

          bind_params!(args, params, row_for(rows, params))
        end

        def row_for(rows, params)
          rows.select { |candidate| params.values.any? { |field| candidate.key?(field) } }
              .sample(random: @binding_random)
        end

        def bind_params!(args, params, row)
          params.each do |param, field|
            args[param] = shaped_like(args[param], row[field]) if row&.key?(field)
          end
        end

        # A single-field value object is written `{"value" => x}` but may be
        # asked with the bare `x`; keeps whichever spelling the generator
        # already chose for this argument.
        def shaped_like(current, written)
          return written unless written.is_a?(Hash) && written.size == 1 && !current.is_a?(Hash)

          written.values.first
        end
      end
    end
  end
end
