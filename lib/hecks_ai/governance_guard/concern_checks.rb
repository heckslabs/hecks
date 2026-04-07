# Hecks::GovernanceGuard::ConcernChecks
#
# Rule-based governance checks for each world concern. These checks
# mirror the validation rules in bluebook but provide richer suggestions
# and work at the governance level (violations + suggestions) rather
# than the validation level (errors only).
#
# Each check method returns [violations, suggestions] arrays.
#
#   checks = ConcernChecks.new(domain)
#   violations, suggestions = checks.check_transparency
#
module Hecks
  class GovernanceGuard
    module ConcernChecks
      module_function

      # Check transparency: every command should emit at least one event.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain]
      # @return [Array(Array<Hash>, Array<String>)] violations and suggestions
      def check_transparency(domain)
        violations = []
        suggestions = []

        domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            next unless cmd.emits.is_a?(Array) && cmd.emits.empty?

            violations << {
              concern: :transparency,
              message: "#{agg.name}##{cmd.name} emits no events -- silent mutations prevent audit trails"
            }
          end
        end

        if violations.any?
          suggestions << "Add 'emits \"EventName\"' to commands or remove 'emits []' to use auto-inferred events"
        end

        no_events_at_all = domain.aggregates.all? { |a| a.events.empty? }
        if no_events_at_all && domain.aggregates.any?
          suggestions << "Consider adding domain events to enable audit logging and reactive policies"
        end

        [violations, suggestions]
      end

      # Check consent: user-like aggregates need actor declarations.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain]
      # @return [Array(Array<Hash>, Array<String>)] violations and suggestions
      def check_consent(domain)
        user_patterns = %w[User Account Member Customer Patient Person Profile]
        violations = []
        suggestions = []

        domain.aggregates.each do |agg|
          next unless user_patterns.any? { |pat| agg.name.include?(pat) }

          agg.commands.each do |cmd|
            next unless cmd.actors.empty?

            violations << {
              concern: :consent,
              message: "#{agg.name}##{cmd.name} has no actor -- consent cannot be verified without knowing who initiated the action"
            }
          end
        end

        if violations.any?
          suggestions << "Add 'actor \"RoleName\"' to commands on user-like aggregates"
        end

        [violations, suggestions]
      end

      # Check privacy: PII must be hidden, PII-aggregate commands need actors.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain]
      # @return [Array(Array<Hash>, Array<String>)] violations and suggestions
      def check_privacy(domain)
        violations = []
        suggestions = []

        domain.aggregates.each do |agg|
          agg.attributes.each do |attr|
            next unless attr.pii? && attr.visible?

            violations << {
              concern: :privacy,
              message: "#{agg.name}##{attr.name} is PII but visible -- exposed in generated UIs and explorers"
            }
          end

          next unless agg.attributes.any?(&:pii?)

          agg.commands.each do |cmd|
            next unless cmd.actors.empty?

            violations << {
              concern: :privacy,
              message: "#{agg.name}##{cmd.name} touches PII aggregate but has no actor -- no audit trail for PII access"
            }
          end
        end

        if violations.any? { |v| v[:message].include?("visible") }
          suggestions << "Add 'visible: false' to PII attributes: attribute :field, String, pii: true, visible: false"
        end

        if violations.any? { |v| v[:message].include?("no actor") }
          suggestions << "Declare who can access PII: actor 'Admin' on commands touching PII aggregates"
        end

        [violations, suggestions]
      end

      # Check security: command actors must be declared at domain level.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain]
      # @return [Array(Array<Hash>, Array<String>)] violations and suggestions
      def check_security(domain)
        domain_actor_names = domain.actors.map(&:name)
        violations = []
        suggestions = []

        domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            cmd.actors.each do |actor|
              actor_name = actor.respond_to?(:name) ? actor.name : actor.to_s
              next if domain_actor_names.include?(actor_name)

              violations << {
                concern: :security,
                message: "#{agg.name}##{cmd.name} declares actor '#{actor_name}' which is not a domain-level actor"
              }
            end
          end
        end

        if violations.any?
          dangling = violations.map { |v| v[:message][/actor '([^']+)'/, 1] }.uniq
          dangling.each do |name|
            suggestions << "Add domain-level actor declaration: actor '#{name}'"
          end
        end

        if domain.actors.empty? && domain.aggregates.any?
          suggestions << "Consider declaring domain-level actors for role-based access control"
        end

        [violations, suggestions]
      end
    end
  end
end
