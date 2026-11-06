module Hecks
  module Adapters
    class PostgresRevisions
      class Lineage
        # ADR 0166: a `split` writes rows into another aggregate from one aggregate's rows. The
        # target's
        # head is not stored: its tail is the source's held-era state, fanned out one row per target
        # key,
        # and read through the same chain every head reads.
        module SplitSql
          # The source's rows as they are in the era the split edge starts from, latest per id, with
          # the
          # era kept so later edges' guards still hold.
          SPLIT_SOURCE_SQL = <<~SQL.freeze
            WITH tail AS MATERIALIZED (%<tail>s),
            %<chain>s
            SELECT ordinal, era, aggregate_id, operation, state FROM edge_%<last>s
          SQL

          # The split edge that creates `names[:current][n]`, with the source aggregate and the
          # split, or nil.
          def split_into(names, edges)
            edges.each_with_index do |edge, index|
              target = names[:current][index + 1]
              edge[:translation].aggregates.each do |source|
                split = source.splits.find { |candidate| candidate.into == target }
                return { index: index, source: source, split: split } if split
              end
            end
            nil
          end

          # The target's tail from its source's held-era rows: the source is chained
          # through the edges that lead into the split edge, so the split reads the shape it
          # declares its fields in.
          def split_tail_sql(names, edges)
            found = split_into(names, edges)
            return nil unless found

            source_sql = split_source_sql(found[:source], edges, found[:index])
            split_fanout_sql(source_sql, found[:split], names[:storage][found[:index] + 1])
          end

          # A split target's records as its split fans them out of the source, latest per id, or nil
          # when
          # the aggregate is not a split target: the "before" side of the audit of a split edge.
          def split_latest(aggregate, edges)
            tail = split_tail_sql(names_by_era(aggregate, edges), edges)
            tail && latest_of("SELECT ordinal, era, aggregate_id, operation, state FROM (#{tail}) split_rows")
          end

          private

          def split_source_sql(source, edges, index)
            through = edges.first(index + 1)
            names = names_by_era(Struct.new(:name).new(source.name), through)
            tail = latest_per_id(ancestor_tail_sql(names, index + 2))
            index.zero? ? tail : split_chain_sql(tail, through.first(index), names)
          end

          def split_chain_sql(tail, edges, names)
            chain = edges.each_with_index.map { |edge, i| edge_step_sql(edge, i, names) }
            format(SPLIT_SOURCE_SQL, tail: tail, chain: chain.join(",\n"), last: edges.size)
          end

          # One row per source row that carries the key: the key becomes the target's id, and the
          # named
          # fields are copied under their own names. Deletes are kept, so a deleted source deletes
          # its
          # target row too.
          def split_fanout_sql(source_sql, split, target_storage)
            key = text_literal(split.keyed_by.to_s)
            # A keyed_by field is often a value object, whose identity is its `value` member.
            key_value = "COALESCE(state -> #{key} ->> 'value', state ->> #{key})"
            fields = split.fields.map { |field| "#{text_literal(field.to_s)}, state -> #{text_literal(field.to_s)}" }
            "SELECT ordinal, era, #{text_literal(target_storage)} AS aggregate, #{key_value} AS aggregate_id, " \
              "operation, jsonb_build_object(#{fields.join(", ")}) AS state " \
              "FROM (#{source_sql}) split_source WHERE state ? #{key}"
          end
        end
      end
    end
  end
end
