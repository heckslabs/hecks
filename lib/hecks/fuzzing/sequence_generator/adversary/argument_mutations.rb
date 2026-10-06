require_relative "../../invalid_value_generator"
require_relative "../../value_generator"
require_relative "../../../runtime/value"

module Hecks
  module Fuzzing
    class SequenceGenerator
      module Adversary
        # The mutations aimed at a step's other arguments: a routing key, a nulled single-field
        # value object, and an omitted mapped argument.
        module ArgumentMutations
          private

          # Not applied over a routed `to:` from `deep_entity_addressing!`; overwriting it would
          # contradict that step's note.
          def routing_key_applicable?(args, _entry, _catalog) = !args.key?("to")

          def apply_routing_key!(args, entry, _catalog)
            key   = ROUTING_KEYS.sample(random: @random)
            shape = ROUTING_SHAPES.sample(random: @random)
            args[key] =
              case shape
              when "null"   then nil
              when "scalar" then routing_scalar(args, entry)
              else               routing_object(args, entry)
              end
            { "mutation" => "routing_key", "bug" => "BUG#7/#16/#8", "key" => key, "shape" => shape,
              "declared" => !entry[:command].attribute(key).nil? }
          end

          # This step's own parent id, an out-of-range Integer, or a minted id nothing holds.
          def routing_scalar(args, entry)
            case @random.rand(3)
            when 0 then parent_scalar_of(args, entry)
            when 1 then ValueGenerator::INTEGER_EDGE_CASES.sample(random: @random)
            else        ValueGenerator.random_id(@random)
            end
          end

          def routing_object(args, entry)
            entities = (entry[:chain] || []).map { |piece| ValueGenerator.scalar_of(args[(piece.identified_by || :id).to_s]) }
            # Half the time one identity too many, a depth the verb lacks, which both engines must
            # refuse alike.
            entities << ValueGenerator.random_id(@random) if @random.rand(2).zero?
            { "aggregate" => parent_scalar_of(args, entry), "entities" => entities }
          end

          def parent_scalar_of(args, entry)
            key = (entry[:aggregate].identified_by || :id).to_s
            args.key?(key) ? ValueGenerator.scalar_of(args[key]) : identity_scalar_of(entry[:aggregate], args)
          end

          def null_value_object_applicable?(args, entry, _catalog) = value_object_targets(args, entry).any?

          def value_object_targets(args, entry)
            aggregate = entry[:aggregate]
            entry[:command].attributes.reject { |attribute| attribute.list? || attribute.reference? }
                           .select { |attribute| args.key?(attribute.name.to_s) }
                           .filter_map do |attribute|
              value_object = Runtime::Value.value_object_for(aggregate, attribute.type.to_s)
              [attribute, value_object] if value_object&.sole_attribute
            end
          end

          def apply_null_value_object!(args, entry, _catalog)
            targets = value_object_targets(args, entry)
            closed  = targets.select { |_, value_object| value_object.closed_set? }
            attribute, value_object = (closed.empty? ? targets : closed).sample(random: @random)
            shape = VALUE_OBJECT_SHAPES.sample(random: @random)
            args[attribute.name.to_s] = shape == "null" ? nil : {}
            { "mutation" => "null_value_object", "bug" => "BUG#14", "argument" => attribute.name.to_s,
              "value_object" => value_object.hecks_name, "closed_set" => value_object.closed_set? == true,
              "shape" => shape }
          end

          def omit_mapped_argument_applicable?(args, entry, _catalog) = mapped_argument_targets(args, entry).any?

          # An append's mapped source arguments, or a plain creating command's non-identity
          # attributes; never an identity head.
          def mapped_argument_targets(args, entry)
            mapped = mapped_names(entry)
            heads  = identity_heads_of(entry)
            needed = needed_facts_of(entry)
            entry[:command].attributes.select do |attribute|
              name = attribute.name.to_s
              mapped.include?(name) && args.key?(name) && !heads.include?(name) && !needed.include?(name)
            end
          end

          # The names of the arguments an append maps into its element, or every attribute of a
          # plain creating command.
          def mapped_names(entry)
            command = entry[:command]
            mapped  = appended_sources(command)
            return mapped unless mapped.empty? && !entry.key?(:entity) && command.creates?

            command.attributes.map { |attribute| attribute.name.to_s }
          end

          # The argument names the command's appends take their element fields from.
          def appended_sources(command)
            command.mutations.select { |mutation| mutation.op == :append }
                   .flat_map { |mutation| mutation.source.values.grep(Symbol).map(&:to_s) }
          end

          def apply_omit_mapped_argument!(args, entry, _catalog)
            attribute = mapped_argument_targets(args, entry).sample(random: @random)
            args.delete(attribute.name.to_s)
            { "mutation" => "omit_mapped_argument", "bug" => "BUG#12", "argument" => attribute.name.to_s,
              "optional" => attribute.optional? == true }
          end
        end
      end
    end
  end
end
