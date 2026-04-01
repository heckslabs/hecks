module Hecks
  module ValidationRules
    module WorldConcerns

      # Hecks::ValidationRules::WorldConcerns::Security
      #
      # When the :security concern is declared, commands that declare actors must
      # reference actors that are also declared at the domain level. This ensures
      # that every role used in access control is a recognized part of the domain
      # model -- no dangling or misspelled actor references.
      #
      #   world_concerns :security
      #
      #   actor "Admin"
      #
      #   aggregate "Config" do
      #     command "UpdateConfig" do
      #       actor "Admin"       # good -- declared at domain level
      #       actor "SuperAdmin"  # violation -- not a domain actor
      #     end
      #   end
      #
      class Security < BaseRule
        def errors
          return [] unless @domain.world_concerns.include?(:security)

          domain_actor_names = @domain.actors.map(&:name)
          issues = []

          @domain.aggregates.each do |agg|
            agg.commands.each do |cmd|
              cmd.actors.each do |actor|
                actor_name = actor.respond_to?(:name) ? actor.name : actor.to_s
                unless domain_actor_names.include?(actor_name)
                  issues << error("Security: #{agg.name}##{cmd.name} declares actor '#{actor_name}' which is not a domain-level actor",
                    hint: "Add a domain-level actor declaration: actor '#{actor_name}'")
                end
              end
            end
          end
          issues
        end
      end
      Hecks.register_validation_rule(Security)
    end
  end
end
