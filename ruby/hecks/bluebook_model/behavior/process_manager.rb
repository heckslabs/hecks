# Hecks::BluebookModel::Behavior::ProcessManager
#
# Intermediate representation of a process manager — an event-driven state
# machine that coordinates multi-step business processes across aggregates.
# Mirrors the runtime class +Hecks::EventSourcing::ProcessManager+ exactly,
# so the bluebook DSL (+process_manager+ keyword) reads as a thin declarative
# wrapper around the existing runtime primitive.
#
# A process manager carries:
#
# * +name+         — PascalCase process manager name
# * +correlates_by+ — Symbol; the event attribute used to correlate events
#                    to a single PM instance
# * +starts_on+    — String; event type that creates a new instance
# * +ends_on+      — String, optional; event type that archives the instance
# * +states+       — Array<String>; explicit state declarations (no inference)
# * +handlers+     — Array<Handler>; one per +on "Event", transition: { x: :y }+
#
# Each Handler is a Struct with +event_type+ (String), +transition+
# (Hash{Symbol => Symbol}, exactly one entry: from => to), and +action+
# (Proc, optional; mirrors the runtime block returning { commands: [...] }).
#
# Part of the BluebookModel IR layer. Built by
# +Hecks::DSL::ProcessManagerBuilder+ in the DSL. Phase 1 of the dream-study
# plan ships the IR + parser only ; runtime instantiation lands in Phase 2.
#
#   pm = ProcessManager.new(
#     name: "SleepCycle",
#     correlates_by: :body_id,
#     starts_on: "SleepStarted",
#     ends_on: "WakeFinished",
#     states: %w[light rem deep studying_dream],
#     handlers: [handler_a, handler_b]
#   )
#   pm.declared?(:rem)      # => true
#   pm.handler_for("PhaseElapsed").transition  # => { light: :light }
#
module Hecks
  module BluebookModel
    module Behavior
      class ProcessManager
        # Hecks::BluebookModel::Behavior::ProcessManager::Handler
        #
        # One on-event handler within a process manager. Mirrors the runtime
        # +Hecks::EventSourcing::ProcessManager::Handler+ shape, minus
        # +correlate+ (the PM declares correlates_by once, runtime threads
        # it into each handler at instantiation time).
        Handler = Struct.new(
          :event_type, :transition, :action, :dispatches,
          keyword_init: true
        ) do
          # Default `dispatches` to [] when caller doesn't provide it.
          # Existing tests using the Ruby-proc form (action set,
          # dispatches absent) construct cleanly.
          def initialize(*)
            super
            self.dispatches ||= []
          end
        end

        # @return [String] the PM name (PascalCase)
        attr_reader :name

        # @return [Symbol] the event attribute used for correlation
        attr_reader :correlates_by

        # @return [String] the event type that starts a new instance
        attr_reader :starts_on

        # @return [String, nil] the event type that ends an instance, if declared
        attr_reader :ends_on

        # @return [Array<String>] declared state names (in declaration order)
        attr_reader :states

        # @return [Array<Handler>] registered event handlers (in declaration order)
        attr_reader :handlers

        # @return [String, nil] human-readable description (from +description+ DSL)
        attr_reader :description

        # Create a new ProcessManager IR node.
        #
        # @param name [String] PascalCase PM name
        # @param correlates_by [Symbol] the correlation event attribute
        # @param starts_on [String] event type that starts a new instance
        # @param states [Array<String>] declared states
        # @param handlers [Array<Handler>] declared on-event handlers
        # @param ends_on [String, nil] optional event type that ends an instance
        # @param description [String, nil] optional description
        def initialize(name:, correlates_by:, starts_on:, states:, handlers:,
                       ends_on: nil, description: nil)
          @name = name.to_s
          @correlates_by = correlates_by.to_sym
          @starts_on = starts_on.to_s
          @ends_on = ends_on.nil? ? nil : ends_on.to_s
          @states = states.map(&:to_s)
          @handlers = handlers
          @description = description
        end

        # @param state [String, Symbol] candidate state name
        # @return [Boolean] true if +state+ was declared via +state "..."+
        def declared?(state)
          @states.include?(state.to_s)
        end

        # @param event_type [String, Symbol] event type to look up
        # @return [Handler, nil] the matching handler, if any
        def handler_for(event_type)
          @handlers.find { |h| h.event_type == event_type.to_s }
        end
      end
    end
  end
end
