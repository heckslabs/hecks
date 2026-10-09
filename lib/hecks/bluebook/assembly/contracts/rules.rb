module Hecks
  module Bluebook
    class Assembly
      # The contracts for the ask, entity and policy; `CONTRACTS` merges every group.
      RULES = {
        "Query"  => Contract.new(
          holder: Query, make: :new,
          fields: {
            name:           [:name,        :plain],
            description:    [:description, :plain],
            attributes:     [:attributes,  [:each, :shape_field]],
            wheres:         [:wheres,          [:each, :where_clause]],
            order_by:       [:order_by,        :order_by],
            limit:          [:limit,           :limit],
            returns:        [:returns,         :plain],
            needs:          [:needs,           [:each, :need]],
            # Held by the language as an open map, so every one of these reads the
            # same way and a ninth option needs no new field on either side.
            offset:         [:offset,          [:option, :offset]],
            cursor:         [:cursor,          [:option, :cursor]],
            null_semantics: [:null_semantics,  [:option, :null_semantics]],
            authorization:  [:authorization,   [:option, :authorization]],
            inspection:     [:inspection,      [:option, :inspection]]
          },
          rows: { wheres: :where_rows, options: :option_rows },
          reads: { attributes: [:each, :shape_field], wheres: [:each, :where_clause],
                  needs: [:each, :need], order_by: [:call, :order_by], limit: [:call, :limit] },
          derived: {
            position:    :walk,
            order_field: [:folded, :order_by, :field],
            order_way:   [:folded, :order_by, :direction],
            options:     [:folded, %i[offset cursor null_semantics authorization inspection], nil]
          }
        ),

        "Entity" => Contract.new(
          holder: Entity, make: :declare,
          fields: {
            name:          [:name,          :plain],
            description:   [:description,   :plain],
            # A list of paths, like Aggregate's. Must be Symbols: a String looks
            # identical here but a symbol-keyed args lookup downstream would find
            # nothing, silently rejecting a value that was in fact passed.
            identified_by: [:identified_by, :plain],
            attributes:    [:attributes,    [:each, :shape_field]],
            # Same shape as Aggregate's own `preconditions`, one level down (ADR 0028).
            preconditions: [:preconditions, [:each, :given]],
            # Same shape as Aggregate's own `invariants`, checked per instance of
            # this entity rather than the aggregate's flat state.
            invariants:    [:invariants,    [:each, :invariant]]
          },
          rows: { transitions: :transition_rows, marks: :mark_rows, identified_by: :identity_rows },
          reads: { identified_by: [:each, :identity_path], attributes: [:each, :shape_field],
                   preconditions: [:each, :rule], invariants: [:each, :rule] },
          derived: {
            position:    :walk,
            owner:       :parent,
            state_field: [:folded, :lifecycle, :field],
            state_start: [:folded, :lifecycle, :default],
            transitions: [:folded, :lifecycle, :transitions],
            marks:       [:folded, :lifecycle, :marks]
          }
        ),

        "Policy" => Contract.new(
          holder: Policy, make: :new,
          fields: {
            name:               [:name,            :plain],
            aggregate:          [:aggregate,       :plain],
            on_event:           [:on_event,        :plain],
            trigger_command:    [:trigger_command, :plain],
            ask:                [:ask,             :plain],
            target_domain:      [:target_domain,   :plain],
            expect_undelivered: [:expect_undelivered, :plain],
            where:              [:where,           :plain],
            for_each:           [:for_each,        :plain],
            with_spec:          [:with_spec,       :bindings]
          },
          rows: { with_spec: :with_spec_rows },
          reads: { with_spec: [:from, :with_spec], expect_undelivered: :expect_undelivered? },
          derived: { position: :walk }
        )
      }.freeze
    end
  end
end
