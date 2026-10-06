module Hecks
  module Bluebook
    class Assembly
      # The contracts for the process manager chain and the syntax records;
      # `CONTRACTS` merges every group.
      SAGAS = {
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
        )
      }.freeze
    end
  end
end
