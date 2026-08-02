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

      # Logged AFTER the step's own work, so a step that wraps sub-steps (see
      # CommandInterpreter#normalize_args, which traces refuse_unknown_arguments
      # internally) logs itself once everything inside it has already logged —
      # trace order is completion order, which is dispatch order.
      def step(name)
        result = yield
        self.class.trace << name if self.class.trace
        result
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
    end
  end
end
