require_relative "behaviour/process_manager"

module Hecksagain
  class Bluebook
    DispatchSpec = Struct.new(:command_name, :with_spec, keyword_init: true) do
      # A Struct already answers to_h; including the mixin puts the
      # DECLARED emission ahead of Struct's own in the ancestry, which
      # is what makes the shape data rather than a method body.
      include Hecksagain::IR

      emits_ir(
        command_name: -> { command_name.to_s },
        with_spec:    -> { with_spec.map { |key, value| [key.to_s, Bluebook.render_value(value)] } }
      )
    end

    ProcessManagerHandler = Struct.new(:event_type, :from_state, :to_state,
                                       :dispatches, keyword_init: true) do
      include Hecksagain::IR

      emits_ir(
        event_type: -> { event_type.to_s },
        from_state: -> { from_state.to_s },
        to_state:   -> { to_state.to_s },
        dispatches: many(:dispatches)
      )
    end

    # The compensation half of a procedure, as its own thing.
    #
    # A PROCESS MANAGER coordinates: legs, states, an opinion about who goes
    # next. A SAGA undoes: what makes the world good again when a leg it
    # dispatched is refused. Two concepts, and the industry slurs them into one
    # word — so here they are two objects, and a procedure either has a saga or
    # does not.
    #
    # `undoes` is the ordered list of commands the compensation sends. Today that
    # order is the AUTHOR's, written by hand in one `on :refused` leg, and the
    # runtime does not know which legs actually completed. When compensation
    # moves beside each dispatch — `reverses` on the step it reverses — this is
    # where the completed ones, newest first, will live. The shape is already
    # right for it; only the source of the order changes.
    Saga = Struct.new(:trigger, :from_state, :to_state, :reversals, keyword_init: true) do
      def undoes = reversals.map(&:command_name)

      def to_s = "#{trigger} → #{to_state} (#{undoes.join(', ')})"
    end

    class ProcessManager

      # The BLUEBOOK's name for this construct, asked the same way of a class
      # that has crossed over and of an IR object that has not. Collapses into
      # Construct when this one crosses.
      # The trigger of a compensating leg. Not an event name — no aggregate
      # announces that a leg the procedure dispatched was declined — so it lives
      # here beside the thing it triggers rather than in the runtime that
      # notices it. Declared in the language's Trigger vocabulary, which
      # spec/vocabulary_conformance_spec holds to this constant.
      REFUSED = "refused".freeze

      include Hecksagain::IR
      include Behaviour::ProcessManager

      emits_ir(
        name:          :name,
        correlates_by: -> { correlates_by.to_s },
        starts_on:     :starts_on,
        ends_on:       :ends_on,
        states:        :states,
        handlers:      many(:handlers)
      )

      attr_reader :name, :correlates_by, :starts_on, :ends_on, :states, :handlers

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
