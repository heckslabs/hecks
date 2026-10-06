module Hecks
  module Fuzzing
    module Properties
      # Independent nestings of a `group_by` read model's rows, for
      # `InvariantsAndAggregation#group_by_matches_recompute` to compare against the answer.
      module GroupByRecompute
        # Judges one `group_by` ask against the rows it was eligible to see:
        # refused exactly when two of them share a checked key path, and
        # otherwise nested exactly as `nest_rows` nests them.
        def group_by_offense(bluebook, asked, model, grouped_head)
          rows = eligible_rows(bluebook, asked.fetch(:instances_at), model, grouped_head, asked[:args] || {})
          materialized = rows.map { |state| Runtime::Value.materialize_unwrapped(state) }
          shared = shared_key_paths(materialized, model.group_by_fields)
          return nesting_offense(asked, model, grouped_head, materialized) if shared.empty?

          collision_offense(asked, model.group_by_fields, shared.length, checked_key_paths?(bluebook, model, grouped_head))
        end

        # Whether the grouped key paths are checked, i.e. do not cover the head's identity.
        def checked_key_paths?(bluebook, model, grouped_head)
          !model.groups_by_identity?(bluebook.aggregate(grouped_head[:aggregate]))
        end

        # Judges an ask with no shared key path: it must not have refused, and its grouping must
        # equal the independent nesting.
        def nesting_offense(asked, model, grouped_head, materialized)
          return nil if asked[:error]
          return nil if asked[:rows]&.first&.dig(grouped_head[:as]) == nest_rows(materialized, model.group_by_fields)

          "#{asked[:query]} #{asked[:args].inspect} answered a #{grouped_head[:as]} grouping that disagrees " \
            "with independently nesting group_by #{model.group_by_fields.inspect} over #{materialized.length} " \
            "eligible row(s)"
        end

        # Judges an ask whose eligible rows share at least one full key path:
        # a checked key path must have refused, and an identity-covering one
        # cannot be shared by rows that hold their identity.
        def collision_offense(asked, fields, shared, checked)
          return nil if checked && asked[:error]

          "#{asked[:query]} #{asked[:args].inspect} #{checked ? "answered" : "reached"}, but #{shared} key " \
            "path(s) of group_by #{fields.inspect} are shared by more than one eligible row, " \
            "#{checked ? "so the ask must refuse" : "though they cover the identity"}"
        end

        # Every full `group_by` key path more than one row reaches, found by
        # tallying each row's tuple of grouped values, with no nesting at all.
        def shared_key_paths(rows, fields)
          rows.map { |row| fields.map { |field| row[field] } }.tally.select { |_, count| count > 1 }.keys
        end

        # One level of nesting per `group_by` field in declared order; the leaf
        # is the row with every grouped field stripped. Called only when no key
        # path is shared (`shared_key_paths` rules that out), so each leaf holds
        # exactly one row; a second row raises rather than being picked over.
        def nest_rows(rows, fields)
          field, *rest = fields
          rows.group_by { |row| row[field] }.transform_values do |group|
            stripped = group.map { |row| row.reject { |key, _| key == field } }
            next nest_rows(stripped, rest) unless rest.empty?
            raise ArgumentError, "nest_rows reached a key path #{stripped.length} rows share" unless stripped.length == 1

            stripped[0]
          end
        end
      end
    end
  end
end
