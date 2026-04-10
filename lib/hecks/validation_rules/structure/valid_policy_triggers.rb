module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::ValidPolicyTriggers
    #
    # Validates that reactive policies reference commands that actually exist
    # in the domain. A reactive policy's +trigger_command+ must match a command
    # defined on some aggregate; otherwise the policy can never fire.
    #
    # Checks both aggregate-level reactive policies and domain-level reactive
    # policies. Non-reactive policies (those without a trigger_command) are skipped.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    # Policy trigger must name an existing command somewhere in the domain.
    class ValidPolicyTriggers < BaseRule
      # Checks all reactive policies (aggregate-scoped and domain-level) and
      # returns errors for any whose +trigger_command+ does not match a known
      # command in the domain. Includes a hint listing available commands.
      #
      # @return [Array<String>] error messages for policies with unknown trigger commands
      def errors
        result = []
        all_commands = collect_all_commands(@domain)

        @domain.aggregates.each do |agg|
          agg.policies.select(&:reactive?).each do |policy|
            unless command_known?(policy.trigger_command, all_commands)
              fix = all_commands.any? ? "Available commands: #{all_commands.join(', ')}" : "Define the target command first"
              result << error("Policy #{policy.name} in #{agg.name} triggers unknown command: #{policy.trigger_command}",
                hint: fix)
            end
          end
        end

        @domain.policies.select(&:reactive?).each do |policy|
          next if policy.target_domain  # cross-domain — validated at the being level
          unless command_known?(policy.trigger_command, all_commands)
            fix = all_commands.any? ? "Available commands: #{all_commands.join(', ')}" : "Define the target command first"
            result << error("Domain policy #{policy.name} triggers unknown command: #{policy.trigger_command}",
              hint: fix)
          end
        end

        result
      end

      private

      def collect_all_commands(domain)
        cmds = domain.aggregates.flat_map { |a| a.commands.map(&:name) }
        cmds += domain.all_commands.map(&:name) if domain.respond_to?(:all_commands)
        cmds.uniq
      end

      # Matches bare names ("RecordEntry") and qualified names
      # ("Identity::AuditLog::RecordEntry") against known commands.
      def command_known?(trigger, all_commands)
        bare = trigger.include?("::") ? trigger.split("::").last : trigger
        all_commands.include?(bare)
      end
    end
    Hecks.register_validation_rule(ValidPolicyTriggers)
    end
  end
end
