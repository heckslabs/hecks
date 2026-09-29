module Hecks
  module Bluebook
    # Reopened for `CONTRACTS`, the table of each category's own `Contract`;
    # see contract.rb for the struct format each entry below fills in.
    class Assembly
      # One table of what each category needs beyond what the language states:
      # holder, make (:declare vs :new), and fields. spec/assembly_spec checks
      # it against the language, so an unconsumed declared field fails loudly.
      def self.contract(category) = CONTRACTS.fetch(category.to_s)

      CONTRACTS = {
        "Bluebook"       => Contract.new(
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

        "Aggregate"      => Contract.new(
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

        "Command"        => Contract.new(
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
            # Lifecycle state as a command guard: one state, an array, or nil (ADR 0025).
            from:       [:from,       :plain],
            provenance: [:provenance, :plain]
          },
          rows: { mutations: :mutation_rows },
          reads: { attributes: [:each, :shape_field], givens: [:each, :rule], ensures: [:each, :rule],
                  mutations: [:call, :mutations], emits: :names, provenance: :provenance, from: :from },
          derived: { position: :walk }
        ),

        "ValueObject"    => Contract.new(
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

        "Query"          => Contract.new(
          holder: Query, make: :new,
          fields: {
            name:           [:name,        :plain],
            description:    [:description, :plain],
            attributes:     [:attributes,  [:each, :shape_field]],
            wheres:         [:wheres,          [:each, :where_clause]],
            order_by:       [:order_by,        :order_by],
            limit:          [:limit,           :limit],
            # Held by the language as an open map, so every one of these reads the
            # same way and a ninth option needs no new field on either side.
            offset:         [:offset,          [:option, :offset]],
            cursor:         [:cursor,          [:option, :cursor]],
            null_semantics: [:null_semantics,  [:option, :null_semantics]],
            authorization:  [:authorization,   [:option, :authorization]],
            inspection:     [:inspection,      [:option, :inspection]],
            answered_by:    [:answered_by,     [:option, :answered_by]]
          },
          rows: { wheres: :where_rows, options: :option_rows },
          reads: { attributes: [:each, :shape_field], wheres: [:each, :where_clause],
                  order_by: [:call, :order_by], limit: [:call, :limit] },
          derived: {
            position:    :walk,
            order_field: [:folded, :order_by, :field],
            order_way:   [:folded, :order_by, :direction],
            options:     [:folded, %i[offset cursor null_semantics authorization inspection answered_by], nil]
          }
        ),

        "Entity"       => Contract.new(
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
          rows: { transitions: :transition_rows, identified_by: :identity_rows },
          reads: { identified_by: [:each, :identity_path], attributes: [:each, :shape_field],
                   preconditions: [:each, :rule], invariants: [:each, :rule] },
          derived: {
            position:    :walk,
            owner:       :parent,
            state_field: [:folded, :lifecycle, :field],
            state_start: [:folded, :lifecycle, :default],
            transitions: [:folded, :lifecycle, :transitions]
          }
        ),

        "Policy"         => Contract.new(
          holder: Policy, make: :new,
          fields: {
            name:               [:name,            :plain],
            aggregate:          [:aggregate,       :plain],
            on_event:           [:on_event,        :plain],
            trigger_command:    [:trigger_command, :plain],
            target_domain:      [:target_domain,   :plain],
            expect_undelivered: [:expect_undelivered, :plain],
            where:              [:where,           :plain],
            for_each:           [:for_each,        :plain],
            with_spec:          [:with_spec,       :bindings]
          },
          rows: { with_spec: :with_spec_rows },
          reads: { with_spec: [:from, :with_spec], expect_undelivered: :expect_undelivered? },
          derived: { position: :walk }
        ),

        "ProcessManager" => Contract.new(
          holder: ProcessManager, make: :new,
          fields: {
            name:          [:name,          :plain],
            # Must be a Symbol: SagaInterpreter looks it up as a symbol-keyed hash
            # key. A String silently matches nothing, and the saga never advances.
            correlates_by: [:correlates_by, :identity],
            starts_on:     [:starts_on,     :plain],
            ends_on:       [:ends_on,       :plain],
            states:        [:states,        :plain]
          },
          reads: { states: :names },
          # `handlers` comes from the judge walking the containment tree
          # (`Handler.parent == "ProcessManager"`), the same as Aggregate's
          # own `value_objects` — not from any field this contract reads.
          derived: { position: :walk, handlers: :children }
        ),

        # Handler is nested under ProcessManager. `event_type` is its real
        # identity (a saga answers each event once), so unlike other entities
        # it has no walk-minted `position` to derive.
        "Handler"        => Contract.new(
          holder: ProcessManagerHandler, make: :new,
          fields: {
            event_type: [:event_type, :plain],
            from_state: [:from_state, :plain],
            to_state:   [:to_state,   :plain]
          },
          # `dispatches` comes from the containment walk, like ProcessManager's
          # own `handlers` above — not from a field this contract reads.
          derived: { dispatches: :children }
        ),

        # Dispatch is nested under Handler, two levels deep. `command_name` alone
        # is not identity — a handler can fan the same command out more than
        # once, so `position` (walk-minted) disambiguates.
        "Dispatch"       => Contract.new(
          holder: DispatchSpec, make: :new,
          fields: {
            command_name: [:command_name, :plain],
            with_spec:    [:with_spec,    :bindings]
          },
          rows: { with_spec: :with_spec_rows, compensates_with_spec: :compensates_with_spec_rows },
          reads: { with_spec: [:from, :with_spec] },
          # compensates_* fold one IR object (`DispatchSpec#compensates`) into two fields.
          derived: {
            position:                 :walk,
            compensates_command_name: [:folded, :compensates, :command_name],
            compensates_with_spec:    [:folded, :compensates, :with_spec]
          }
        ),

        # Syntax/Keyword/Argument bypass Build/Reconstruction entirely (ADR 0026) —
        # SyntaxBoot reads them directly. These entries exist only so assembly_spec
        # can hold them to the same "every field claimed" discipline as the rest.
        "Syntax"         => Contract.new(
          holder: nil, make: nil,
          fields: { name: [:name, :plain] },
          derived: { keywords: :children, arguments: :children }
        ),

        "Keyword"        => Contract.new(
          holder: nil, make: nil,
          fields: {
            word:          [:word,          :plain],
            context:       [:context,       :plain],
            body:          [:body,          :plain],
            inner:         [:inner,         :plain],
            opens:         [:opens,         :plain],
            fills:         [:fills,         :plain],
            was:           [:was,           :plain],
            resolves_via:  [:resolves_via,  :plain],
            disambiguator: [:disambiguator, :plain],
            calls:         [:calls,         :plain]
          },
          derived: { position: :walk }
        ),

        "Argument"       => Contract.new(
          holder: nil, make: nil,
          fields: {
            keyword:          [:keyword,          :plain],
            context:          [:context,          :plain],
            at:               [:at,               :plain],
            named:            [:named,            :plain],
            kind:             [:kind, :plain],
            required:         [:required,         :plain],
            fills:            [:fills,            :plain],
            selects:          [:selects,          :plain],
            pair_key_fills:   [:pair_key_fills,   :plain],
            pair_value_fills: [:pair_value_fills, :plain],
            pairs_shape:      [:pairs_shape,      :plain],
            variadic:         [:variadic,         :plain],
            minimum:          [:minimum,          :plain],
            coerce:           [:coerce,           :plain],
            blank_message:    [:blank_message,    :plain]
          },
          derived: { position: :walk }
        ),

        "ReadModel"      => Contract.new(
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
        "Member"         => Contract.new(
          holder: nil, make: nil,
          fields: {},
          rows: { pairs: :pair_rows },
          derived: { position: :walk, pairs: [:folded, %i[members], nil] }
        )
      }.freeze
    end
  end
end
