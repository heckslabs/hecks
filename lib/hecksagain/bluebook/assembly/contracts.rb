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
      #             instance — the boundary `Query` sits on, since its body is
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
          holder: Chapter, make: :new,
          fields: {
            name:           [:name,           :plain],
            version:        [:version,        :plain],
            vision:         [:vision,         :plain],
            classification: [:classification, :plain],
            formerly_known_as: [:formerly_known_as, :plain]
          },
          rows: { normalisations: :normalisation_table },
          derived: { normalisations: :elsewhere }
        ),

        "Aggregate" => Contract.new(
          holder: Aggregate, make: :new,
          fields: {
            name:          [:name,          :plain],
            description:   [:description,   :plain],
            identified_by: [:identified_by, :plain],
            attributes:    [:attributes,    [:each, :attribute]],
            # THE AGGREGATE BOUNDARY, and the precondition a command may
            # reference by name (S10, ADR 0025 — "Rules"). Same reader
            # shapes ValueObject's own `invariants`/Command's own
            # `givens` already use — `invariant` builds an Invariant,
            # `given` a Given, the same struct AggregateBuilder#given
            # hands a referencing command's own resolved list.
            invariants:    [:invariants,    [:each, :invariant]],
            preconditions: [:preconditions, [:each, :given]],
            provenance:    [:provenance,    :plain]
          },
          rows: { transitions: :transition_rows, value_objects: :value_object_names, identified_by: :identity_rows },
          reads: { identified_by: [:each, :identity_path], attributes: [:each_with_id, :attribute],
                   invariants: [:each, :rule], preconditions: [:each, :rule] },
          derived: {
            position: :walk,
            state_field:   [:folded, :lifecycle, :field],
            state_start:   [:folded, :lifecycle, :default],
            transitions:   [:folded, :lifecycle, :transitions],
            value_objects: :children
          }
        ),

        "Command" => Contract.new(
          holder: Command, make: :declare,
          fields: {
            name:       [:name,       :plain],
            role:       [:role,       :plain],
            goal:       [:goal,       :plain],
            references: [:references, :plain],
            attributes: [:attributes, [:each, :shape_field]],
            givens:     [:givens,     [:each, :given]],
            ensures:    [:ensures,    [:each, :given]],
            mutations:  [:mutations,  [:each, :mutation]],
            emits:      [:emits,      :plain],
            # LIFECYCLE STATE AS A COMMAND GUARD (S10, ADR 0025) — a
            # literal the same way `provenance`/`default:` already are;
            # one state or an array of them, or nil for a command with
            # no such guard.
            from:       [:from,       :plain],
            provenance: [:provenance, :plain]
          },
          rows: { mutations: :mutation_rows },
          reads: { attributes: [:each, :shape_field], givens: [:each, :rule], ensures: [:each, :rule],
                  mutations: [:call, :mutations], emits: :names, provenance: :provenance, from: :from },
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
                  closed_set: [:call, :closed_set_of], members: [:call, :members_row] },
          derived: { position: :walk, rows: [:folded, %i[closed_set members], nil] }
        ),

        "Query" => Contract.new(
          holder: Query, make: :new,
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
            inspection:      [:inspection,      [:option, :inspection]]
          },
          rows: { wheres: :where_rows, options: :option_rows },
          reads: { attributes: [:each, :shape_field], wheres: [:each, :where_clause],
                  order_by: [:call, :order_by], limit: [:call, :limit] },
          derived: {
            position: :walk,
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
            # A LIST OF PATHS, exactly as an aggregate's is. The two used to differ
            # — a Symbol here and a String there, which byte equality with `to_h`
            # COULD NOT SEE because both render as a string, so the assembled graph
            # got a String and `element_of` looked up `args["sequence"]` in a
            # symbol-keyed payload and found nothing: "Reverse acts on one
            # LedgerEntry — pass sequence:", while passing sequence. There is one
            # spelling now, and no room left for that difference.
            identified_by: [:identified_by, :plain],
            attributes:    [:attributes,    [:each, :shape_field]]
          },
          rows: { transitions: :transition_rows, identified_by: :identity_rows },
          reads: { identified_by: [:each, :identity_path], attributes: [:each, :shape_field] },
          derived: {
            position: :walk,
            owner:       :parent,
            state_field: [:folded, :lifecycle, :field],
            state_start: [:folded, :lifecycle, :default],
            transitions: [:folded, :lifecycle, :transitions]
          }
        ),

        "Policy" => Contract.new(
          holder: Policy, make: :new,
          fields: {
            name:            [:name,            :plain],
            aggregate:       [:aggregate,       :plain],
            on_event:        [:on_event,        :plain],
            trigger_command: [:trigger_command, :plain],
            target_domain:   [:target_domain,   :plain],
            where:           [:where,           :plain],
            for_each:        [:for_each,        :plain],
            with_spec:       [:with_spec,       :bindings]
          },
          rows: { with_spec: :with_spec_rows },
          reads: { with_spec: [:from, :with_spec] },
          derived: { position: :walk }
        ),

        "ProcessManager" => Contract.new(
          holder: ProcessManager, make: :new,
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
          derived: { position: :walk }
        ),

        "Handler" => Contract.new(
          holder: ProcessManagerHandler, make: :new,
          fields: {
            event_type: [:event_type, :plain],
            from_state: [:from_state, :plain],
            to_state:   [:to_state,   :plain]
          },
          derived: { position: :walk }
        ),

        "Dispatch" => Contract.new(
          holder: DispatchSpec, make: :new,
          fields: {
            command_name: [:command_name, :plain],
            with_spec:    [:with_spec,    :bindings]
          },
          rows: { with_spec: :with_spec_rows },
          reads: { with_spec: [:from, :with_spec] },
          derived: { position: :walk, handler: :parent }
        ),

        "ReadModel" => Contract.new(
          holder: ReadModel, make: :new,
          fields: {
            name:             [:name,             :plain],
            description:      [:description,      :plain],
            reference_name:   [:reference_name,   :identity],
            reference_target: [:reference_target, :plain],
            aggregate_heads:  [:aggregate_heads,  [:each, :head]],
            group_by:         [:group_by,         [:each, :group_by_field]],
            # `count`/`median_field` are `group_by`'s own two siblings —
            # scalars, not lists, so no `[:each, ...]` shape ; `:plain`
            # is what `Assembly::Build` needs (fed the native `to_h`
            # value directly, already `true`/`nil`/a String), and the
            # `reads:` entry below is what `Reconstruction` needs
            # instead (fed the STRINGIFIED meta-domain row).
            count:            [:count,            :plain],
            median_field:     [:median_field,     :plain],
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
          # `wheres` needs its own reader for the same reason Query's does — a
          # list defaults to `[]`, not the generic `text(row[key])` cell reader's
          # `nil` — even though a read model's row never carries `wheres` as a
          # native field the way Query's does (`[:each, :where_clause]` over an
          # absent `row[:wheres]` is `Array(nil).map { ... }`, i.e. `[]`, always).
          # The REAL values, when a read model declares any, arrive through
          # `options_of(row)`'s merge in `read_model` below (dispatched as
          # generic Option rows, `read_model_option_rows`/`filter_options` — not
          # as dedicated where-clause rows), which overrides this default. Until
          # `ReadModel#to_h` spelled `wheres`/`order_by`/`limit`
          # unconditionally, `round_trip_spec`'s own "SOURCE KEYS ONLY" +compare
          # never asked about this key at all, so the `nil`-vs-`[]` gap between
          # this contract's default and `to_h`'s own `[]` default went unnoticed.
          # `order_by`/`limit` need no matching entry — the generic reader's
          # `nil` already agrees with `to_h`'s own nil-when-undeclared default
          # for those two. `group_by` needs its own reader the same way — a
          # rootless read model's grouping keys, added independently on main.
          reads: { reference_name: :symbol, aggregate_heads: [:each, :head],
                  group_by: [:each, :group_by_field], wheres: [:each, :where_clause],
                  # `count` needs the boolean coercion `Shapes#read_model_count`
                  # gives it (a stringified "true"/absent on the wire, a real
                  # `true`/`nil` in `to_h`) — `median_field` needs none: the
                  # default `text(row[key])` cell reader already returns the
                  # same String-or-nil `ReadModel#to_h`'s own `&.to_s` does.
                  count: :read_model_count },
          derived: {
            position: :walk,
            query_name: [:computed, :query_name],
            options:    [:folded, %i[offset cursor null_semantics authorization inspection], nil]
          }
        ),

        # A member's pairs are an OPEN MAP, which is why Member is its own root in
        # the language. The IR keeps them as a plain hash on the value object, so
        # they are assembled with their shape rather than as a construct.
        "Member" => Contract.new(
          holder: nil, make: nil,
          fields: {},
          rows: { pairs: :pair_rows },
          derived: { position: :walk, shape: :parent, pairs: [:folded, %i[members], nil] }
        )
      }.freeze
    end
  end
end
