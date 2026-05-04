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
# [antibody-exempt: ruby/hecks/bluebook_model/behavior/process_manager.rb —
#  kernel-floor IR struct, Phase 2.c set_specs field mirrors rust/src/ir.rs.
#  i221-A — DispatchSpec.for_each_spec + ForEachSpec + ValueSpec :from_iter
#  mirror the same parity-locked surface in rust/src/ir.rs.]
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
        #
        # Phase 2.c — +set_specs+ carries the declarative
        # +set :attr, value_spec+ list captured from the on-block.
        # Each entry is +[attr_name_string, ValueSpec]+. Empty when no
        # +set+ was declared. Mirrors +rust/src/ir.rs+ ProcessManagerHandler.
        Handler = Struct.new(
          :event_type, :transition, :action, :dispatches, :set_specs,
          keyword_init: true
        ) do
          # Default `dispatches` and `set_specs` to [] when caller
          # doesn't provide them. Existing tests using the Ruby-proc
          # form (action set, the new fields absent) construct cleanly.
          def initialize(*)
            super
            self.dispatches ||= []
            self.set_specs  ||= []
          end
        end

        # Hecks::BluebookModel::Behavior::ProcessManager::DispatchSpec
        #
        # One declarative `dispatch "Cmd", with: {...}` entry inside an
        # on-handler block. Carries the command name plus an ordered list
        # of [attr_name, ValueSpec] pairs declared via `with:`. Empty
        # +with_spec+ means the dispatch fires with no explicit attrs ;
        # the runtime auto-injects upstream refs the same way the bare
        # `dispatch "Cmd"` form does today.
        #
        # i221-A — sweep dispatch : when +for_each_spec+ is non-nil the
        # runtime fires the dispatch once per record returned by the
        # named query. +nil+ means a bare / single-record dispatch (the
        # back-compat default for every existing dispatch).
        DispatchSpec = Struct.new(
          :command_name, :with_spec, :for_each_spec,
          keyword_init: true
        ) do
          def initialize(*)
            super
            self.with_spec ||= []
          end
        end

        # Hecks::BluebookModel::Behavior::ProcessManager::ForEachSpec
        #
        # Sweep source on a +DispatchSpec+. i221-A — the runtime reads
        # the named query at dispatch time and fires the receiving
        # command once per returned record ; +from_iter(:field)+ in the
        # +with:+ hash reads the iteration record's +field+ attribute.
        #
        # +source_context+   — optional bluebook context (Hecks.bluebook
        #                      "Name"). Nil for the 2-part
        #                      +"Aggregate.query"+ form ; set for the
        #                      3-part +"Context.Aggregate.query"+ form
        #                      that disambiguates same-named aggregates
        #                      across multiple bluebooks (i142
        #                      Context.Aggregate.Command resolution
        #                      applied to query lookups).
        # +source_aggregate+ — qualified aggregate name (middle / left
        #                      half of the literal).
        # +query_name+        — query identifier (right half).
        ForEachSpec = Struct.new(
          :source_context, :source_aggregate, :query_name,
          keyword_init: true
        )

        # Hecks::BluebookModel::Behavior::ProcessManager::ValueSpec
        #
        # Sentinel value class describing how a single +with:+ attribute is
        # resolved at dispatch time. Four kinds :
        #
        #   :literal     — the source value carried as-is
        #   :from_event  — read +event.data[name]+ at dispatch ; +default+
        #                  fires when the key is absent
        #   :from_pm     — read +pm_instance.data[name]+ at dispatch ;
        #                  +default+ fires when the key is absent
        #   :from_iter   — i221-A — read +iter_record.data[field]+ during
        #                  a +for_each:+ sweep dispatch
        #
        # +default+ is +nil+ when omitted ; runtime treats nil-default as
        # "leave the key unset on the dispatched command's input".
        ValueSpec = Struct.new(
          :kind, :name, :value, :default,
          keyword_init: true
        )

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
