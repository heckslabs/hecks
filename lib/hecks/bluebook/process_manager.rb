require_relative "behaviour/process_manager"
require_relative "../ir"

module Hecks
  module Bluebook
    # `compensates` is a second `DispatchSpec` naming the command that undoes this one, or nil.
    # Never nested; `reverses` stays reserved for `corrects`.
    DispatchSpec = Struct.new(:command_name, :with_spec, :compensates, keyword_init: true) do
      # Struct already answers to_h; the mixin puts the declared emission ahead of it.
      include Hecks::IR

      emits_ir(
        command_name: -> { command_name.to_s },
        with_spec:    -> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } },
        compensates:  one(:compensates)
      )
    end

    ProcessManagerHandler = Struct.new(:event_type, :from_state, :to_state,
                                       :dispatches, keyword_init: true) do
      include Hecks::IR

      emits_ir(
        event_type: -> { event_type.to_s },
        from_state: -> { from_state.to_s },
        to_state:   -> { to_state.to_s },
        dispatches: many(:dispatches)
      )
    end

    # The compensation half of a procedure: the commands sent to undo a refused leg.
    # `undoes` is a static declaration-order preview; per-instance order is the runtime's.
    Saga = Struct.new(:trigger, :from_state, :to_state, :compensations, keyword_init: true) do
      def undoes = compensations.map(&:command_name)

      def to_s = "#{trigger} → #{to_state} (#{undoes.join(', ')})"
    end

    # The built form of a `process_manager "Name" do ... end` block, made by
    # `DSL::ProcessManagerBuilder`.
    class ProcessManager
      # The trigger of a compensating leg. Not an event name: no aggregate announces a declined
      # leg. Held to the language's Trigger vocabulary by spec/vocabulary_conformance_spec.
      REFUSED = Hecks::Vocabulary.fetch("Trigger").first

      include Hecks::IR
      include Behaviour::ProcessManager

      emits_ir(
        name:          :name,
        # `&.` because the IR class defaults `correlates_by` to nil; `.to_s` reads back as `""`.
        # A bare Symbol string, not `Literal.render`, to match the golden IR fixtures.
        correlates_by: -> { correlates_by&.to_s },
        starts_on:     :starts_on,
        ends_on:       :ends_on,
        states:        :states,
        handlers:      many(:handlers)
      )

      attr_reader :name, :correlates_by, :starts_on, :ends_on, :states, :handlers

      # @param correlates_by [Symbol, nil] the payload field that correlates a triggering
      #   event to an instance
      # @param starts_on [String, nil] the event that starts a new instance
      # @param ends_on [String, nil] the event that ends an instance
      def initialize(name:, correlates_by: nil, starts_on: nil, ends_on: nil,
                     states: [], handlers: [])
        @name          = name.to_s
        @correlates_by = correlates_by
        @starts_on     = starts_on
        @ends_on       = ends_on
        @states        = states
        @handlers      = handlers
      end
    end
  end
end
