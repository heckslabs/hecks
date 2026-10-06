module Hecks
  module Bluebook
    class Assembly
      # The contracts for the read model and the member; `CONTRACTS` merges every group.
      READ_MODELS = {
        "ReadModel" => Contract.new(
          holder: ReadModel, make: :new,
          fields: {
            name:             [:name,             :plain],
            description:      [:description,      :plain],
            reference_name:   [:reference_name,   :identity],
            reference_target: [:reference_target, :plain],
            aggregate_heads:  [:aggregate_heads,  [:each, :head]],
            group_by:         [:group_by,         [:each, :group_by_field]],
            # Scalars, not lists: `:plain` is for Build (native to_h value);
            # the `reads:` entry below is for Reconstruction (stringified row).
            count:            [:count,            :plain],
            median_field:     [:median_field,     :plain],
            sum_field:        [:sum_field,        :plain],
            avg_field:        [:avg_field,        :plain],
            min_field:        [:min_field,        :plain],
            max_field:        [:max_field,        :plain],
            percentile_field: [:percentile_field, :plain],
            percentile_at:    [:percentile_at,    :plain],
            any_field:        [:any_field,        :plain],
            all_field:        [:all_field,        :plain],
            # A read model inherits every option an ask has, so it reads them the
            # same way — see Query.
            wheres:           [:wheres,           [:each, :where_clause]],
            order_by:         [:order_by,         :order_by],
            limit:            [:limit,            :limit],
            offset:           [:offset,           [:option, :offset]],
            cursor:           [:cursor,           [:option, :cursor]],
            null_semantics:   [:null_semantics,   [:option, :null_semantics]],
            authorization:    [:authorization,    [:option, :authorization]],
            inspection:       [:inspection,       [:option, :inspection]]
          },
          rows: { options: :read_model_option_rows },
          # `wheres` needs its own reader so an undeclared list defaults to `[]`,
          # not the generic reader's `nil`; real values arrive via the options
          # merge in `read_model` below, which overrides this default.
          reads: { reference_name: :symbol, aggregate_heads: [:each, :head],
                  group_by: [:each, :group_by_field], wheres: [:each, :where_clause],
                  # `count` needs boolean coercion (stringified on the wire);
                  # `median_field` needs none — the default reader already
                  # matches `to_h`'s String-or-nil.
                  count: :read_model_count,
                  # `percentile_at` needs Float coercion; every other reduction field
                  # is a Symbol-like name the default text reader already matches.
                  percentile_at: :read_model_percentile_at },
          derived: {
            position:   :walk,
            query_name: [:computed, :query_name],
            options:    [:folded, %i[offset cursor null_semantics authorization inspection], nil]
          }
        ),

        # Member is nested under ValueObject. Its pairs are an open map, so it
        # holds no `shape` field — only walk-minted `position` and `pairs`
        # (still one row per entry, still an open map).
        "Member"    => Contract.new(
          holder: nil, make: nil,
          fields: {},
          rows: { pairs: :pair_rows },
          derived: { position: :walk, pairs: [:folded, %i[members], nil] }
        )
      }.freeze
    end
  end
end
