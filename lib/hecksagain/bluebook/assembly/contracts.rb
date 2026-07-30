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
      Contract = Struct.new(:holder, :make, :fields, :derived, keyword_init: true) do
        def declares?(field) = fields.key?(field) || derived.include?(field)
      end

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
          # The canonical-form table belongs to the expression grammar, not to any
          # one chapter — `IR::Bluebook#to_h` splices it in and never reads it back.
          derived: %i[normalisations aggregates read_models policies process_managers]
        ),

        "Aggregate" => Contract.new(
          holder: IR::Aggregate, make: :new,
          fields: {
            name:          [:name,          :plain],
            description:   [:description,   :plain],
            identified_by: [:identified_by, :identity],
            attributes:    [:attributes,    [:each, :attribute]]
          },
          # state_field / state_start / transitions are ONE lifecycle object in the
          # IR, so the assembly builds it from the `lifecycle:` the spelling holds.
          # The child categories are assembled by the containment tree.
          derived: %i[state_field state_start transitions value_objects commands
                      entities queries lifecycle policies reference_targets]
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
          derived: []
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
          # `rows` is the language's count of admitted rows ; the IR keeps the rows
          # themselves and a flag, both of which are above.
          derived: %i[rows]
        ),

        "Query" => Contract.new(
          holder: IR::Query, make: :new,
          fields: {
            name:        [:name,        :plain],
            description: [:description, :plain],
            attributes:  [:attributes,  [:each, :shape_field]],
            wheres:      [:wheres,      [:each, :where_clause]],
            order_by:    [:order_by,    :order_by],
            limit:       [:limit,       :limit]
          },
          # Two language fields, one IR object — the same difference in the other
          # direction.
          derived: %i[order_field order_way]
        ),

        "Entity" => Contract.new(
          holder: IR::Entity, make: :declare,
          fields: {
            name:          [:name,          :plain],
            description:   [:description,   :plain],
            identified_by: [:identified_by, :plain],
            attributes:    [:attributes,    [:each, :shape_field]]
          },
          # `owner` is the parent pointer the containment tree already knows. A
          # piece's identified_by is a STRING where a head's is a Symbol, and only a
          # round trip ever said so.
          derived: %i[owner state_field state_start transitions commands queries lifecycle]
        ),

        "Policy" => Contract.new(
          holder: IR::Policy, make: :new,
          fields: {
            name:            [:name,            :plain],
            on_event:        [:on_event,        :plain],
            trigger_command: [:trigger_command, :plain],
            target_domain:   [:target_domain,   :plain]
          },
          derived: []
        ),

        "ProcessManager" => Contract.new(
          holder: IR::ProcessManager, make: :new,
          fields: {
            name:          [:name,          :plain],
            correlates_by: [:correlates_by, :plain],
            starts_on:     [:starts_on,     :plain],
            ends_on:       [:ends_on,       :plain],
            states:        [:states,        :plain]
          },
          derived: %i[handlers]
        ),

        "Handler" => Contract.new(
          holder: IR::ProcessManagerHandler, make: :new,
          fields: {
            event_type: [:event_type, :plain],
            from_state: [:from_state, :plain],
            to_state:   [:to_state,   :plain]
          },
          derived: %i[dispatches]
        ),

        "Dispatch" => Contract.new(
          holder: IR::DispatchSpec, make: :new,
          fields: {
            command_name: [:command_name, :plain],
            with_spec:    [:with,         :bindings]
          },
          # `handler` is the parent pointer.
          derived: %i[handler]
        ),

        "ReadModel" => Contract.new(
          holder: IR::ReadModel, make: :new,
          fields: {
            name:             [:name,             :plain],
            description:      [:description,      :plain],
            reference_name:   [:reference_name,   :identity],
            reference_target: [:reference_target, :plain],
            aggregate_heads:  [:aggregate_heads,  [:each, :head]]
          },
          # `query_name` is Naming.snake(name) — computed, never stored.
          derived: %i[query_name]
        ),

        # A member's pairs are an OPEN MAP, which is why Member is its own root in
        # the language. The IR keeps them as a plain hash on the value object, so
        # they are assembled with their shape rather than as a construct.
        "Member" => Contract.new(
          holder: nil, make: nil,
          fields: {},
          derived: %i[shape pairs]
        )
      }.freeze
    end
  end
end
