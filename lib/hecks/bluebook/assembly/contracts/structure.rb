module Hecks
  module Bluebook
    class Assembly
      # The contracts for the chapter, aggregate, command and value object;
      # `CONTRACTS` merges every group.
      STRUCTURE = {
        "Bluebook"    => Contract.new(
          holder: Chapter, make: :new,
          fields: {
            name:              [:name,           :plain],
            version:           [:version,        :plain],
            vision:            [:vision,         :plain],
            classification:    [:classification, :plain],
            formerly_known_as: [:formerly_known_as, :plain],
            namespace:         [:namespace, :plain],
            attaches_to:       [:attaches_to, :plain],
            provides:          [:provides, :plain]
          },
          rows: { normalisations: :normalisation_table },
          derived: { normalisations: :elsewhere }
        ),

        "Aggregate"   => Contract.new(
          holder: Aggregate, make: :new,
          fields: {
            name:             [:name,          :plain],
            description:      [:description,   :plain],
            identified_by:    [:identified_by, :plain],
            attributes:       [:attributes,    [:each, :attribute]],
            # Aggregate's own precondition, referenced by name from a command (ADR 0025).
            invariants:       [:invariants,    [:each, :invariant]],
            preconditions:    [:preconditions, [:each, :given]],
            # The local half of `projects :name, from: "reference.remote_field"` (ADR 0025).
            projected_fields: [:projected_fields, [:each, :projected_field]],
            provenance:       [:provenance, :plain]
          },
          rows: { transitions: :transition_rows, value_objects: :value_object_names, identified_by: :identity_rows },
          reads: { identified_by: [:each, :identity_path], attributes: [:each_with_id, :attribute],
                   invariants: [:each, :rule], preconditions: [:each, :rule],
                   projected_fields: [:each, :projected_field] },
          derived: {
            position:      :walk,
            state_field:   [:folded, :lifecycle, :field],
            state_start:   [:folded, :lifecycle, :default],
            transitions:   [:folded, :lifecycle, :transitions],
            value_objects: :children
          }
        ),

        "Command"     => Contract.new(
          holder: Command, make: :declare,
          fields: {
            name:       [:name,       :plain],
            role:       [:role,       :plain],
            goal:       [:goal,       :plain],
            references: [:references, :plain],
            attributes: [:attributes, [:each, :shape_field]],
            givens:     [:givens,     [:each, :given]],
            ensures:    [:ensures,    [:each, :given]],
            needs:      [:needs,      [:each, :need]],
            mutations:  [:mutations,  [:each, :mutation]],
            emits:      [:emits,      :plain],
            # Lifecycle state as a command guard: one state, an array, or nil (ADR 0025).
            from:       [:from,       :plain],
            provenance: [:provenance, :plain]
          },
          rows: { mutations: :mutation_rows },
          reads: { attributes: [:each, :shape_field], givens: [:each, :rule], ensures: [:each, :rule],
                  needs: [:each, :need], mutations: [:call, :mutations], emits: :names, provenance: :provenance,
                  from: :from },
          derived: { position: :walk }
        ),

        "ValueObject" => Contract.new(
          holder: ValueObject, make: :declare,
          fields: {
            name:       [:name,       :plain],
            attributes: [:attributes, [:each, :shape_field]],
            invariants: [:invariants, [:each, :invariant]],
            members:    [:members,    [:each, :member]],
            closed_set: [:closed_set, :flag]
          },
          # The language counts the admitted rows ; the IR keeps a flag and the rows.
          reads: { attributes: [:each, :shape_field], invariants: [:each, :rule],
                  closed_set: [:call, :closed_set?], members: [:call, :members_row] },
          derived: { position: :walk, rows: [:folded, %i[closed_set members], nil] }
        )
      }.freeze
    end
  end
end
