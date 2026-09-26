require_relative "../../query_specification/field_path"
require_relative "../../runtime/value"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Query arguments drawn from what the sequence has already written.
      #
      # A query is only a real test of an adapter when its argument names a row
      # that exists. A `where(site_reference: :site_reference)` asked with a
      # freshly generated word matches nothing on every adapter, so an adapter
      # that compiles the comparison wrongly (and so also matches nothing) is
      # indistinguishable from a correct one. Every argument `args_for` draws
      # is independent of the store, and the chance that one lands on a stored
      # value is small enough that a whole persistence-parity sweep can pass
      # without a single query returning a row.
      #
      # ## What is written, and what is bound
      #
      # After each command that took effect, every aggregate a query filters
      # on is read back from the repository, and the values of exactly the
      # fields those queries compare (`bound_fields`) are remembered as one
      # row per record. A row is what the store holds, not what a command was
      # given, so a value a `sets` mapping renamed, a policy wrote in another
      # aggregate, or a lifecycle transition assigned is covered too. A later
      # query step usually takes its arguments from one remembered row, so
      # several parameters filter the same record. The rest of the time it
      # keeps the generated argument, which is what reaches the empty answer.
      #
      # ## Why a separate random stream
      #
      # The choice draws from its own `Random`, seeded from the sequence's
      # seed and restarted wherever `@random` is (`restart_random`). Drawing
      # from `@random` would shift every later step of every seed. This way
      # each seed generates the same commands, in the same order, with the
      # same arguments as before, and only the arguments of a query step
      # change. A query changes no state, so nothing downstream moves.
      module QueryBinding
        # How often a query step whose aggregate has written rows takes its
        # arguments from one of them. High, because a query that misses a
        # stored row tests nothing, and the miss is still drawn the other
        # quarter of the time.
        BOUND_QUERY_PROBABILITY = 0.75

        # Comparators whose argument is one scalar or value, so a stored value
        # is a legitimate operand. `in` takes a list and `none_in_state` an
        # `"Aggregate:state"` string; a stored value is neither.
        BINDABLE_OPERATORS = %i[eq ne lt lte gt gte].freeze

        # Keeps the binding stream apart from `@random`'s, which is seeded
        # with the bare seed.
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
            repository.all.each do |record|
              row = binding[:fields].to_h { |field| [field, written_value(field_of(record, field))] }.compact
              @written_rows[key] << row unless row.empty? || @written_rows[key].include?(row)
            end
          end
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
          return if rows.empty? || params.empty?
          return unless @binding_random.rand < BOUND_QUERY_PROBABILITY

          row = rows.select { |candidate| params.values.any? { |field| candidate.key?(field) } }
                    .sample(random: @binding_random)
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
