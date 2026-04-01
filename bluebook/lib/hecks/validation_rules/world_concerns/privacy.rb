module Hecks
  module ValidationRules
    module WorldConcerns

      # Hecks::ValidationRules::WorldConcerns::Privacy
      #
      # When the :privacy concern is declared, PII attributes must be marked
      # +visible: false+ so they are hidden from generated UIs and explorers.
      # Additionally, commands on aggregates containing PII must declare an
      # actor so there is an audit trail of who accessed or modified PII.
      #
      #   world_concerns :privacy
      #
      #   aggregate "Patient" do
      #     attribute :ssn, String, pii: true, visible: false  # good
      #     attribute :email, String, pii: true                 # violation: visible PII
      #   end
      #
      class Privacy < BaseRule
        def errors
          return [] unless @domain.world_concerns.include?(:privacy)

          issues = []
          @domain.aggregates.each do |agg|
            check_visible_pii(agg, issues)
            check_pii_commands_need_actor(agg, issues)
          end
          issues
        end

        private

        def check_visible_pii(agg, issues)
          agg.attributes.each do |attr|
            if attr.pii? && attr.visible?
              issues << error("Privacy: #{agg.name}##{attr.name} is PII but visible",
                hint: "Add visible: false to the attribute: attribute :#{attr.name}, String, pii: true, visible: false")
            end
          end
        end

        def check_pii_commands_need_actor(agg, issues)
          return unless agg.attributes.any?(&:pii?)

          agg.commands.each do |cmd|
            if cmd.actors.empty?
              issues << error("Privacy: #{agg.name}##{cmd.name} touches PII aggregate but has no actor",
                hint: "Declare who can access PII: actor 'Admin'")
            end
          end
        end
      end
      Hecks.register_validation_rule(Privacy)
    end
  end
end
