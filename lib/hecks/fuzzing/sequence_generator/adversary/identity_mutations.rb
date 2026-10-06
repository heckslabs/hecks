module Hecks
  module Fuzzing
    class SequenceGenerator
      module Adversary
        # The mutations aimed at a step's identity arguments: a blanked identity part, and an
        # entity identity offered a second time under the same parent.
        module IdentityMutations
          private

          def blank_identity_applicable?(args, entry, catalog) = blank_identity_targets(args, entry, catalog).any?

          # Identity heads this step supplies: a creating command's own (every composite part) and
          # an append's entity identity arguments.
          def blank_identity_targets(args, entry, catalog)
            targets = creating_identity_heads(entry)
            populator = populator_for_entry(catalog, entry)
            targets += populator[:identity_arguments].map(&:to_s) if populator
            targets.uniq.select { |head| args.key?(head) }
          end

          # A creating command's own identity heads, every part of a composite.
          def creating_identity_heads(entry)
            return [] unless entry[:entity].nil? && entry[:command].creates?

            aggregate = entry[:aggregate]
            heads = composite_identity?(aggregate) ? aggregate.identity_heads : [aggregate.identified_by || :id]
            heads.map(&:to_s)
          end

          def apply_blank_identity!(args, entry, catalog)
            head  = blank_identity_targets(args, entry, catalog).sample(random: @random)
            shape = BLANK_SHAPES.sample(random: @random)
            blank = shape == "empty" ? "" : "   "
            args[head] =
              if shape == "null" then nil
              elsif args[head].is_a?(Hash) then args[head].transform_values { blank }
              else blank
              end
            { "mutation" => "blank_identity", "bug" => "BUG#15", "argument" => head, "shape" => shape }
          end

          def duplicate_entity_identity_applicable?(args, entry, catalog) = duplicate_identity_pool(args, entry, catalog).any?

          def duplicate_identity_pool(args, entry, catalog)
            populator = populator_for_entry(catalog, entry)
            return [] unless populator && populator[:identity_arguments].any?

            @appended_identities[append_pool_key(populator, args)]
          end

          def apply_duplicate_entity_identity!(args, entry, catalog)
            populator = populator_for_entry(catalog, entry)
            tuple     = duplicate_identity_pool(args, entry, catalog).sample(random: @random)
            args.merge!(tuple)
            { "mutation" => "duplicate_entity_identity", "bug" => "BUG#13", "entity" => populator[:entity].hecks_name,
              "composite" => populator[:identity_arguments].size > 1, "identity" => tuple }
          end
        end
      end
    end
  end
end
