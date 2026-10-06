require_relative "../invalid_value_generator"
require_relative "../value_generator"
require_relative "../../runtime/value"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Draws a step's arguments from the RNG, occasionally malforming exactly one of them.
      module ArgumentDrawing
        private

        # `needed` names the facts the runtime answers when a step leaves them out; a malformation
        # never drops one, since each engine would fill it from its own clock.
        def args_for(attributes, aggregate, needed: [])
          args = attributes.each_with_object({}) do |attribute, built|
            # Omitting an optional argument is an ordinary payload, not a malformation
            # (see OPTIONAL_OMITTED_PROBABILITY).
            next if attribute.optional? && @random.rand < SequenceGenerator::OPTIONAL_OMITTED_PROBABILITY

            if attribute.list?
              add_list_value(built, attribute, aggregate)
            else
              built[attribute.name.to_s] = ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids)
            end
          end

          malform(args, attributes, aggregate, needed)
        end

        # `list_value_for` answers nil for a list of entities (those are
        # populated by per-element append commands), so the step skips it.
        def add_list_value(built, attribute, aggregate)
          value = list_value_for(attribute, aggregate)
          built[attribute.name.to_s] = value unless value.nil?
        end

        # An array of 0-3 independently generated elements shaped like the bare
        # element type. `nil`, not `[]`, when the element type is not a value object.
        def list_value_for(attribute, aggregate)
          value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
          return nil unless value_object

          Array.new(@random.rand(0..3)) { ValueGenerator.value_for(attribute, aggregate, random: @random, known_ids: @known_ids) }
        end

        # At most one malformation per step, so the check that fired is identifiable.
        # The rate stays low because refused steps reach no state.
        def malform(args, attributes, aggregate, needed)
          return args if args.empty? || @random.rand >= MALFORMED_ARGUMENT_PROBABILITY

          case @random.rand(3)
          when 0 then corrupt_one(args, attributes, aggregate)
          when 1 then drop_one(args, aggregate, needed)
          else        args.merge([InvalidValueGenerator.undeclared_argument(random: @random)].to_h)
          end
        end

        # Never drops the identity: an auto-minted id is unreproducible, so the
        # step's outcome could not be replayed.
        def drop_one(args, aggregate, needed)
          identity  = (aggregate.identified_by || :id).to_s
          droppable = args.keys - [identity, "id"] - needed
          return args if droppable.empty?

          args.reject { |name, _| name == droppable.sample(random: @random) }
        end

        def corrupt_one(args, attributes, aggregate)
          named = attributes.reject(&:list?).select { |attribute| args.key?(attribute.name.to_s) }
          return args if named.empty?

          attribute = named.sample(random: @random)
          args.merge(attribute.name.to_s => InvalidValueGenerator.corrupt(attribute, aggregate, random: @random))
        end
      end
    end
  end
end
