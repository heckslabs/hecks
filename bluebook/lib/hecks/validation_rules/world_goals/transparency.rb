module Hecks
  module ValidationRules
    module WorldGoals

      # Hecks::ValidationRules::WorldGoals::Transparency
      #
      # When the :transparency goal is declared, every command must emit at least
      # one domain event. Silent mutations violate transparency because observers
      # and audit logs have no way to know a change occurred.
      #
      #   world_goals :transparency
      #
      #   # violation: a command with no events
      #   command "DeleteRecord" do
      #     attribute :id, String
      #     emits []          # <-- transparency rule flags this
      #   end
      #
      class Transparency < BaseRule
        def errors
          return [] unless @domain.world_goals.include?(:transparency)

          issues = []
          @domain.aggregates.each do |agg|
            agg.commands.each do |cmd|
              if cmd.emits.is_a?(Array) && cmd.emits.empty?
                issues << error("Transparency: #{agg.name}##{cmd.name} emits no events",
                  hint: "Add emits 'EventName' or remove emits [] to use auto-inferred events")
              end
            end
          end
          issues
        end
      end
      Hecks.register_validation_rule(Transparency)
    end
  end
end
