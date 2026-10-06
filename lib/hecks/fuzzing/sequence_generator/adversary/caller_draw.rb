require_relative "../../value_generator"

module Hecks
  module Fuzzing
    class SequenceGenerator
      module Adversary
        # The caller a role-gated command is dispatched under: drawn per `role_draw:`, or parked by
        # the refusal-precedence mutation.
        module CallerDraw
          private

          def role_draw? = @role_draw.positive?

          # `[caller, note]`: the caller StepBuilder binds around the dispatch (nil for the
          # unchecked control) and the note for the step's `"adversarial"` metadata. A caller
          # parked by `refusal_precedence` wins; an ungated command draws nothing.
          def caller_draw!(entry, catalog)
            return take_precedence_caller if @precedence_caller

            role = entry[:command].role.to_s
            return [nil, nil] if !role_draw? || role.empty? || @random.rand >= @role_draw

            drawn_caller(role, catalog)
          end

          def take_precedence_caller
            caller = @precedence_caller
            @precedence_caller = nil
            [caller, nil]
          end

          def drawn_caller(role, catalog)
            shapes = CALLER_SHAPES.dup
            shapes.delete("actor_known") if @granted[role].empty?
            shape  = shapes.sample(random: @random)
            caller = caller_for_shape(shape, role, catalog)
            note   = { "mutation" => "caller_role", "angle" => "ANGLE-5", "shape" => shape, "gated_role" => role }
            [caller, caller ? note.merge(caller) : note]
          end

          def caller_for_shape(shape, role, catalog)
            case shape
            when "matching"      then { "role" => role }
            when "mismatched"    then { "role" => other_role(role, catalog) }
            when "actor_known"   then { "role" => role, "actor_id" => @granted[role].sample(random: @random) }
            when "actor_unknown" then { "role" => role, "actor_id" => ValueGenerator.random_id(@random) }
            end
          end

          # Another declared role when there is one (a real wrong hat), else a role none names.
          def other_role(role, catalog)
            others = catalog[:roles] - [role]
            others.empty? ? UNKNOWN_ROLE : others.sample(random: @random)
          end

          # Aims a grant at a role some command declares; random role text would make `actor_known`
          # unreachable. Does nothing without the role draw.
          def steer_grant!(args, entry, catalog)
            return unless role_draw? && catalog[:grant_verbs].include?(entry[:verb]) && catalog[:roles].any?
            return unless args.key?("role_name")

            args["role_name"] = { "value" => catalog[:roles].sample(random: @random) }
          end
        end
      end
    end
  end
end
