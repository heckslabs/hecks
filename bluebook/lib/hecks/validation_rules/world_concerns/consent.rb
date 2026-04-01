module Hecks
  module ValidationRules
    module WorldConcerns

      # Hecks::ValidationRules::WorldConcerns::Consent
      #
      # When the :consent concern is declared, commands on user-like aggregates
      # must declare at least one actor. User-like aggregates are identified
      # by name heuristic: User, Account, Member, Customer, Patient, Person,
      # Profile.
      #
      # Without an actor declaration, there is no record of who initiated the
      # action -- consent cannot be verified.
      #
      #   world_concerns :consent
      #
      #   aggregate "Patient" do
      #     command "UpdateRecord" do
      #       attribute :notes, String
      #       actor "Doctor"          # <-- required by consent rule
      #     end
      #   end
      #
      class Consent < BaseRule
        USER_PATTERNS = %w[
          User Account Member Customer Patient Person Profile
        ].freeze

        def errors
          return [] unless @domain.world_concerns.include?(:consent)

          issues = []
          @domain.aggregates.each do |agg|
            next unless user_like?(agg.name)

            agg.commands.each do |cmd|
              if cmd.actors.empty?
                issues << error("Consent: #{agg.name}##{cmd.name} has no actor",
                  hint: "Add an actor declaration: actor 'Admin' or actor 'User'")
              end
            end
          end
          issues
        end

        private

        def user_like?(name)
          USER_PATTERNS.any? { |pat| name.include?(pat) }
        end
      end
      Hecks.register_validation_rule(Consent)
    end
  end
end
