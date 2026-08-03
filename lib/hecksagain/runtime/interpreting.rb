require_relative "value"

module Hecksagain
  module Runtime
    # What every stepwise interpreter shares: the traced step, and the
    # coercion of a command's declared arguments. Two copies of each lived
    # in CommandInterpreter and EntityInterpreter, where they could only
    # ever drift.
    module Interpreting
      # Each including interpreter gets its own `trace` — set by a spec to
      # observe dispatch order (Vocabulary::AggregateDispatchOrder and
      # Vocabulary::EntityDispatchOrder in language/bluebook/vocabulary.bluebook);
      # nil in production, always — one array push and a nil check per step
      # is the entire cost of leaving this in.
      def self.included(interpreter)
        interpreter.singleton_class.attr_accessor :trace
      end

      private

      # Logged AFTER the step's own work, so a step that wraps sub-steps logs
      # itself once everything inside it has already logged — trace order is
      # completion order, which is dispatch order.
      def step(name)
        result = yield
        self.class.trace << name if self.class.trace
        result
      end

      # DRIVES `DISPATCH_ORDER` (CommandInterpreter/EntityInterpreter, each
      # mirroring its own Vocabulary::*DispatchOrder — vocabulary.bluebook,
      # held equal to it by spec/vocabulary_conformance_spec.rb) by `send`ing
      # each declared step name against the including interpreter's own
      # `step_<name>` handler, in declared order. What used to be `call`'s own
      # literal sequence of method calls is now DATA driving that sequence —
      # tracing a real dispatch and comparing it to the declaration is
      # tautological once `call` mechanically follows the declaration; a
      # conditional step (assign_creation_attributes, advance_lifecycle) still
      # has to guard ITSELF at the top of its own handler and skip tracing
      # when it does not fire, rather than the caller branching around it —
      # see CommandInterpreter#step_assign_creation_attributes.
      def run_dispatch_order(order, ctx)
        order.each { |name| send(:"step_#{name}", ctx) }
      end

      # Every declared attribute present in the payload passes the reference
      # gate, then coercion — the same walk whether the command acts on an
      # aggregate or on one of its entity's elements.
      def coerce_declared_arguments(aggregate, command, args)
        command.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          Value.refuse_object_reference(command, attribute, normalized[attribute.name])
          normalized[attribute.name] = Value.for_attribute(aggregate, attribute, normalized[attribute.name])
        end
      end

      # Coercion only — CommandInterpreter's own refuse_unknown_arguments/
      # refuse_absent_arguments are separate DISPATCH_ORDER steps now (the
      # declared vocabulary lists all three as flat, sequential members, not
      # one nesting the other two), and EntityInterpreter never had them here
      # at all (an entity inherits its aggregate's own gate). One copy,
      # shared, rather than the two identical ones that used to drift.
      def normalize_args(aggregate, command, args)
        coerce_declared_arguments(aggregate, command, args)
      end
    end
  end
end
