module Hecksagain
  module Bluebook
    class Assembly
      # ONE TABLE, WHERE THERE WERE FIVE HAND-WRITTEN MIRRORS OF IT.
      #
      # `bluebook.bluebook` already declares what every construct is made of, and
      # `Plan` already reads it — parent, fields, lists, setters. What the language
      # cannot say is the three things Ruby needs to rebuild one, so those are here
      # and ONLY those:
      #
      #   holder    which class holds it
      #   make      :declare for a construct that became a class, :new for an
      #             instance — the boundary `IR::Query` sits on, since its body is
      #             inherited instance methods
      #   fields    each keyword the constructor takes, as
      #             keyword => [key in the declaration, how to read it]
      #
      # A READER is a symbol naming a method on Marks, or :plain for a value that
      # needs no decoding, or [:each, reader] for a list. Nothing here is a rule
      # about whether a declaration is admissible — the language settled that on the
      # way in. This is only how a spelling becomes an object again.
      #
      # WHY A TABLE AND NOT A METHOD PER CATEGORY. The judge used to carry one
      # hand-written branch per category, and the price was fourteen verbs the
      # language declared and the walk never offered — every rule hanging off them
      # decoration, and nothing red, because a branch that does not exist cannot
      # fail. An assembler with a method per category is the same shape. So the
      # table is checked AGAINST the language by spec/assembly_spec: a field the
      # language declares that no contract consumes is a failure, not a silence.
      #
      # The `derived` list is how a field says it needs no assembling — a parent
      # pointer the containment tree already knows, or something computed from what
      # is here (`query_name` is `Naming.snake(name)`, `creates?` is whether a verb
      # names a root). Naming one is a claim, and the coverage gate holds it.
      def self.contract(category) = CONTRACTS.fetch(category.to_s)

      CONTRACTS = {
        "Bluebook" => Contract.new(
          holder: IR::Bluebook, make: :new,
          fields: {
            name:           [:name,           :plain],
            version:        [:version,        :plain],
            vision:         [:vision,         :plain],
            classification: [:classification, :plain]
          },
          rows: { normalisations: :normalisation_table },
          derived: { normalisations: :elsewhere }
        ),

        "Aggregate" => Contract.new(
          holder: IR::Aggregate, make: :new,
          fields: {
            name:          [:name,          :plain],
            description:   [:description,   :plain],
            identified_by: [:identified_by, :identity],
            attributes:    [:attributes,    [:each, :attribute]]
          },
          rows: { transitions: :transition_rows, value_objects: :value_object_names },
          reads: { identified_by: :symbol, attributes: [:each_with_id, :attribute] },
          derived: {
            state_field:   [:folded, :lifecycle, :field],
            state_start:   [:folded, :lifecycle, :default],
            transitions:   [:folded, :lifecycle, :transitions],
            value_objects: :children
          }
        ),

        "Command" => Contract.new(
          holder: IR::Command, make: :declare,
          fields: {
            name:       [:name,       :plain],
            role:       [:role,       :plain],
            goal:       [:goal,       :plain],
            references: [:references, :plain],
            attributes: [:attributes, [:each, :shape_field]],
            givens:     [:givens,     [:each, :given]],
            mutations:  [:mutations,  [:each, :mutation]],
            emits:      [:emits,      :plain]
          },
          rows: { mutations: :mutation_rows },
          reads: { attributes: [:each, :shape_field], givens: [:each, :rule], mutations: [:call, :mutations], emits: :names },
          derived: {}
        ),

        "ValueObject" => Contract.new(
          holder: IR::ValueObject, make: :declare,
          fields: {
            name:       [:name,       :plain],
            attributes: [:attributes, [:each, :shape_field]],
            invariants: [:invariants, [:each, :invariant]],
            members:    [:members,    [:each, :member]],
            closed_set: [:closed_set, :flag]
          },
          # The language counts the admitted rows ; the IR keeps a flag and the rows.
          reads: { attributes: [:each, :shape_field], invariants: [:each, :rule],
                  closed_set: [:call, :closed_set_of], members: [:call, :members_row] },
          derived: { rows: [:folded, %i[closed_set members], nil] }
        ),

        "Query" => Contract.new(
          holder: IR::Query, make: :new,
          fields: {
            name:        [:name,        :plain],
            description: [:description, :plain],
            attributes:  [:attributes,  [:each, :shape_field]],
            wheres:          [:wheres,          [:each, :where_clause]],
            order_by:        [:order_by,        :order_by],
            limit:           [:limit,           :limit],
            # Held by the language as an OPEN MAP, so every one of these reads the
            # same way and a ninth option needs no new field on either side.
            offset:          [:offset,          [:option, :offset]],
            cursor:          [:cursor,          [:option, :cursor]],
            null_semantics:  [:null_semantics,  [:option, :null_semantics]],
            authorization:   [:authorization,   [:option, :authorization]],
            consistency:     [:consistency,     [:option, :consistency]],
            freshness:       [:freshness,       [:option, :freshness]],
            inspection:      [:inspection,      [:option, :inspection]],
            index_hints:     [:index_hints,     :index_hints]
          },
          rows: { wheres: :where_rows, options: :option_rows },
          reads: { attributes: [:each, :shape_field], wheres: [:each, :where_clause],
                  order_by: [:call, :order_by], limit: [:call, :limit] },
          derived: {
            order_field: [:folded, :order_by, :field],
            order_way:   [:folded, :order_by, :direction],
            options:     [:folded, %i[offset cursor null_semantics authorization
                                       consistency freshness inspection index_hints], nil]
          }
        ),

        "Entity" => Contract.new(
          holder: IR::Entity, make: :declare,
          fields: {
            name:          [:name,          :plain],
            description:   [:description,   :plain],
            # A SYMBOL, though `Entity#to_h` spells it `&.to_s` where an aggregate's
            # `to_h` keeps the symbol. The IR is not uniform about this, and byte
            # equality with `to_h` CANNOT SEE the difference — both sides render as a
            # string. So the assembled graph got a String, and `element_of` looked up
            # `args["sequence"]` in a symbol-keyed payload and found nothing: "Reverse
            # acts on one LedgerEntry — pass sequence:", while passing sequence.
            identified_by: [:identified_by, :identity],
            attributes:    [:attributes,    [:each, :shape_field]]
          },
          rows: { transitions: :transition_rows },
          reads: { attributes: [:each, :shape_field] },
          derived: {
            owner:       :parent,
            state_field: [:folded, :lifecycle, :field],
            state_start: [:folded, :lifecycle, :default],
            transitions: [:folded, :lifecycle, :transitions]
          }
        ),

        "Policy" => Contract.new(
          holder: IR::Policy, make: :new,
          fields: {
            name:            [:name,            :plain],
            aggregate:       [:aggregate,       :plain],
            on_event:        [:on_event,        :plain],
            trigger_command: [:trigger_command, :plain],
            target_domain:   [:target_domain,   :plain]
          },
          derived: {}
        ),

        "ProcessManager" => Contract.new(
          holder: IR::ProcessManager, make: :new,
          fields: {
            name:          [:name,          :plain],
            # A SYMBOL. `SagaInterpreter` does `event.payload[pm.correlates_by]` — a
            # hash lookup on a symbol-keyed payload — and `value == pm.correlates_by`
            # when resolving a leg s bindings. A String there finds nothing and
            # resolves to nothing, so the wire never advanced and a drawer that
            # should have held 2500 held 0. to_h could not show it: it stringifies.
            correlates_by: [:correlates_by, :identity],
            starts_on:     [:starts_on,     :plain],
            ends_on:       [:ends_on,       :plain],
            states:        [:states,        :plain]
          },
          reads: { states: :names },
          derived: {}
        ),

        "Handler" => Contract.new(
          holder: IR::ProcessManagerHandler, make: :new,
          fields: {
            event_type: [:event_type, :plain],
            from_state: [:from_state, :plain],
            to_state:   [:to_state,   :plain]
          },
          derived: {}
        ),

        "Dispatch" => Contract.new(
          holder: IR::DispatchSpec, make: :new,
          fields: {
            command_name: [:command_name, :plain],
            with_spec:    [:with,         :bindings]
          },
          rows: { with_spec: :with_spec_rows },
          reads: { with: [:from, :with_spec] },
          derived: { handler: :parent }
        ),

        "ReadModel" => Contract.new(
          holder: IR::ReadModel, make: :new,
          fields: {
            name:             [:name,             :plain],
            description:      [:description,      :plain],
            reference_name:   [:reference_name,   :identity],
            reference_target: [:reference_target, :plain],
            aggregate_heads:  [:aggregate_heads,  [:each, :head]],
            # A read model inherits every option an ask has, so it reads them the
            # same way — see Query.
            wheres:           [:wheres,           [:each, :where_clause]],
            order_by:         [:order_by,         :order_by],
            limit:            [:limit,            :limit],
            offset:           [:offset,           [:option, :offset]],
            cursor:           [:cursor,           [:option, :cursor]],
            null_semantics:   [:null_semantics,   [:option, :null_semantics]],
            authorization:    [:authorization,    [:option, :authorization]],
            consistency:      [:consistency,      [:option, :consistency]],
            freshness:        [:freshness,        [:option, :freshness]],
            inspection:       [:inspection,       [:option, :inspection]],
            index_hints:      [:index_hints,      :index_hints]
          },
          rows: { options: :read_model_option_rows },
          reads: { reference_name: :symbol, aggregate_heads: [:each, :head] },
          derived: {
            query_name: [:computed, :query_name],
            options:    [:folded, %i[offset cursor null_semantics authorization
                                      consistency freshness inspection index_hints], nil]
          }
        ),

        # A member's pairs are an OPEN MAP, which is why Member is its own root in
        # the language. The IR keeps them as a plain hash on the value object, so
        # they are assembled with their shape rather than as a construct.
        "Member" => Contract.new(
          holder: nil, make: nil,
          fields: {},
          rows: { pairs: :pair_rows },
          derived: { shape: :parent, pairs: [:folded, %i[members], nil] }
        )
      }.freeze
    end
  end
end
