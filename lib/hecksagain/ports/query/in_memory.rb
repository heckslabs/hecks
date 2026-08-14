require_relative "ordering"
require_relative "../../runtime/value"
require_relative "../../query_specification/field_path"

module Hecksagain
  module Ports
    module Query
      module InMemory
        FieldPath = QuerySpecification::FieldPath

        module_function

        def execute(records, declared, args = {}, registry: nil)
          matched = records.select do |record|
            declared.wheres.all? { |clause| holds?(clause, comparable(FieldPath.dig(record, clause.field)), args, registry: registry) }
          end
          field   = declared.order_by&.field
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(FieldPath.dig(record, field)) }
          # OFFSET FIRST, THEN LIMIT — the order SQL means by `LIMIT n
          # OFFSET m`, which is what `SqlQueryBuilder` emits and therefore
          # what every SQL-backed aggregate already answers. Written the
          # other way round here, and the two engines disagreed on the
          # same declaration: `limit 2, offset 1` over three rows is rows
          # two and three in Postgres and Sqlite, and was row two alone in
          # memory. Silently — a short page reads exactly like a page that
          # ran out of rows.
          #
          # It gets worse the further you page, which is the case nobody
          # writing the first page ever sees: at `limit 10, offset 10`,
          # taking ten and then dropping ten leaves NOTHING, so page two
          # of a memory-backed query came back empty however many rows
          # were really there.
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched
        end

        # The same 8 comparators QuerySpecification::Common::COMPARATORS
        # declares, plus `none_in_state` (a 9th, vendored addition — see
        # Runtime::QueryInterpreter#none_in_state?'s own comment). This is
        # the path that actually runs for a memory- or heki-backed
        # aggregate query ; QueryInterpreter#holds? only runs for
        # entity/sub-list queries, or when no adapter implements :query at
        # all. `none_in_state` had ONLY ever been added to that other
        # copy of this same case statement — an ordinary aggregate-level
        # Memory query's own `none_in_state` where-clause fell to the
        # `else` branch below (`held == want`, an id string against
        # "Aggregate:state", never equal) and silently excluded every
        # row, every time.
        def holds?(clause, held, args, registry: nil)
          want = comparable(resolve(clause.value, args))

          case clause.op.to_s
          when "eq"       then held == want
          when "ne"       then held != want
          when "lt"       then ordered?(held, want) && held < want
          when "lte"      then ordered?(held, want) && held <= want
          when "gt"       then ordered?(held, want) && held > want
          when "gte"      then ordered?(held, want) && held >= want
          when "in"       then members(want).include?(held.to_s)
          when "contains" then contains?(held, want)
          when "none_in_state" then none_in_state?(held, want, registry)
          else                 held == want
          end
        end

        # `want` is "Aggregate:state" (a literal), `held` is this row's
        # own field value (already unwrapped by `comparable`) — the exact
        # same reading as `Runtime::QueryInterpreter#none_in_state?`,
        # mirrored here because this module has no `@registry` of its own
        # to close over (a stateless, `module_function` comparator table)
        # and takes one as an explicit argument instead. No registry — no
        # way to look the target up — reads as "not excluded", the same
        # graceful default `registry.repository(...).find` missing a
        # record already falls back to below.
        def none_in_state?(held, want, registry)
          return true unless registry

          aggregate_name, state = want.to_s.split(":", 2)
          target = find_aggregate_by_name(registry, aggregate_name)
          return true unless target

          target_domain, target_ir = target
          record = registry.repository(target_domain, target_ir).find(held)
          return true unless record

          comparable(record.state[:state]) != state
        end

        def find_aggregate_by_name(registry, name)
          registry.bluebooks.each do |domain, bluebook|
            aggregate = bluebook.aggregates.find { |a| a.hecks_name == name }
            return [domain, aggregate] if aggregate
          end
          nil
        end

        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # A list of value objects is a list of single-field hashes — unwrap
        # each element the same way a scalar field is, before stringifying.
        # This is `in`'s own reading of ITS ARGUMENT (a caller may legitimately
        # pass "a,b,c" meaning "any of these") — unrelated to `contains`,
        # which reads the STORED field and never splits it this way. See
        # `contains?`.
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
        end

        # `contains` means two different things depending on what is HELD —
        # real ELEMENT membership for a `list_of` field (a genuine Array
        # arrives already, one element one member, nothing to split), and
        # plain SUBSTRING for anything else. It used to fall through to
        # `members`' comma-split for the scalar case too, silently reading a
        # free-text field's own comma as a separator — which the SQL side's
        # `instr`/`position` never did, so the two disagreed the moment a
        # scalar's real content held a comma. Matching SQL's substring
        # reading here, rather than the other way around, keeps every
        # engine (Memory, Heki, Sqlite, Postgres, the reference interpreter)
        # answering `contains` identically for the same declared field.
        def contains?(held, want)
          return members(held).include?(want.to_s) if held.is_a?(Array)

          held.to_s.include?(want.to_s)
        end

        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          return value unless value.is_a?(Hash)

          numeric = value.values.find { |field| field.is_a?(Numeric) }
          return numeric if numeric
          return value.values.first if value.size == 1

          value
        end
      end
    end
  end
end
