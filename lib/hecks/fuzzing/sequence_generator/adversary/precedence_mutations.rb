require_relative "../../invalid_value_generator"
require_relative "../../value_generator"

module Hecks
  module Fuzzing
    class SequenceGenerator
      module Adversary
        # The refusal-precedence mutation: several faults in one step, so both engines must pick
        # which refusal wins.
        module PrecedenceMutations
          # The parts one precedence mutation has been asked for, what it recorded, and what it
          # applied.
          PrecedencePlan = Struct.new(:wanted, :detail, :applied) do
            def wanted?(part) = wanted.include?(part)

            def record(part, key, value)
              detail[key] = value
              applied << part
            end

            # Reported as what was done: a single-attribute command cannot carry both a drop and a
            # corruption.
            def report = detail.merge("shape" => applied.sort.join("+"))
          end

          private

          def refusal_precedence_applicable?(args, entry, _catalog)
            precedence_shapes_for(args, entry).any?
          end

          # Every shape whose parts this step can carry. `nonexistent` and `lifecycle` need a
          # record-addressing command with flat addressing; `lifecycle` also a guarded command;
          # `role` a declared role.
          def precedence_shapes_for(args, entry)
            can = {
              "mismatch"    => corruptible_attributes(args, entry).any?,
              "absent"      => droppable_required_attributes(args, entry).any?,
              "unknown"     => true,
              "nonexistent" => acts_on_record?(args, entry),
              "lifecycle"   => acts_on_record?(args, entry) && transition_guarded?(entry),
              "role"        => !entry[:command].role.to_s.empty?
            }
            PRECEDENCE_SHAPES.select { |shape| shape.split("+").all? { |part| can.fetch(part) } }
          end

          def acts_on_record?(args, entry) = !entry[:command].creates? && !args.key?("to")

          def transition_guarded?(entry)
            command = entry[:command]
            owner   = entry.key?(:entity) ? entry[:entity] : entry[:aggregate]
            return true if command.from
            return false unless owner.respond_to?(:lifecycle)

            owner.lifecycle&.transitions_for(command.hecks_name)&.any? || false
          end

          def apply_refusal_precedence!(args, entry, catalog)
            corruptible = corruptible_attributes(args, entry)
            droppable   = droppable_required_attributes(args, entry)
            plan = PrecedencePlan.new(precedence_shapes_for(args, entry).sample(random: @random).split("+"),
                                      { "mutation" => "refusal_precedence", "bug" => "BUG#7/#8/#14" }, [])

            corruptible = drop_absent!(args, droppable, corruptible, plan) if plan.wanted?("absent")
            corrupt_mismatch!(args, entry, corruptible, plan) if plan.wanted?("mismatch") && corruptible.any?
            add_unknown!(args, plan) if plan.wanted?("unknown")
            apply_late_stage_parts!(args, entry, plan, catalog)
            plan.report
          end

          # Drops one required attribute; answers the corruptible attributes that remain.
          def drop_absent!(args, droppable, corruptible, plan)
            dropped = droppable.sample(random: @random)
            args.delete(dropped.name.to_s)
            plan.record("absent", "absent", dropped.name.to_s)
            corruptible - [dropped]
          end

          def corrupt_mismatch!(args, entry, corruptible, plan)
            attribute = corruptible.sample(random: @random)
            args[attribute.name.to_s] = InvalidValueGenerator.corrupt(attribute, entry[:aggregate], random: @random)
            plan.record("mismatch", "mismatched", attribute.name.to_s)
          end

          def add_unknown!(args, plan)
            name, value = InvalidValueGenerator.undeclared_argument(random: @random)
            args[name] = value
            plan.record("unknown", "unknown", name)
          end

          # The parts past the argument gate. `nonexistent` re-addresses the last hop to an id
          # nothing holds; `lifecycle` mutates nothing and is recorded so the pairing is visible;
          # `role` parks a mismatched caller for StepBuilder to bind around the dispatch.
          def apply_late_stage_parts!(args, entry, plan, catalog)
            readdress_nonexistent!(args, entry, plan) if plan.wanted?("nonexistent")
            plan.record("lifecycle", "lifecycle", entry[:command].from || "transition-guarded") if plan.wanted?("lifecycle")
            return unless plan.wanted?("role")

            @precedence_caller = { "role" => other_role(entry[:command].role.to_s, catalog) }
            plan.record("role", "role", @precedence_caller["role"])
          end

          def readdress_nonexistent!(args, entry, plan)
            piece = (entry[:chain] || []).last || entry[:aggregate]
            head  = (piece.identified_by || :id).to_s
            args[head] = identity_shaped(piece, piece.identified_by, ValueGenerator.random_id(@random), entry[:aggregate])
            plan.record("nonexistent", "nonexistent", head)
          end

          def corruptible_attributes(args, entry)
            entry[:command].attributes.reject(&:list?).select { |attribute| args.key?(attribute.name.to_s) }
          end

          def droppable_required_attributes(args, entry)
            heads  = identity_heads_of(entry)
            needed = needed_facts_of(entry)
            entry[:command].attributes.reject(&:optional?).select do |attribute|
              name = attribute.name.to_s
              args.key?(name) && !heads.include?(name) && !needed.include?(name)
            end
          end
        end
      end
    end
  end
end
