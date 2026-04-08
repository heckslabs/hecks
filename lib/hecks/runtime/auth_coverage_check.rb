# Hecks::Runtime::AuthCoverageCheck
#
# Validates that domains declaring actor requirements on commands have
# auth middleware registered. Raises +ConfigurationError+ at boot when
# actors are declared but no auth extension is wired, preventing silent
# security gaps.
#
#   # Automatically called after extensions fire during Hecks.boot
#   # To opt out explicitly:
#   runtime.extend(:auth, enforce: false)
#
module Hecks
  class Runtime
    # Hecks::Runtime::AuthCoverageCheck
    #
    # Validates at boot that domains with actor-protected commands have auth middleware registered.
    #
    module AuthCoverageCheck
      # Scans the domain IR for commands with actor declarations and
      # verifies that auth middleware is registered on the command bus.
      #
      # Raises +Hecks::ConfigurationError+ if actor-protected commands
      # exist but no +:auth+ middleware is registered.
      #
      # @return [void]
      # @raise [Hecks::ConfigurationError] when actors declared without auth
      def check_auth_coverage!
        protected_commands = actor_protected_commands
        return if protected_commands.empty?
        return if auth_middleware_registered?

        names = protected_commands.map(&:name).join(", ")
        count = protected_commands.size
        raise Hecks::ConfigurationError,
          "Domain '#{@domain.name}' declares actor requirements on " \
          "#{count} command#{'s' unless count == 1} (#{names}) but no " \
          "auth middleware is registered. Add `extend :auth` to your " \
          "Hecks.boot or Hecks.configure block, or explicitly opt out " \
          "with `extend :auth, enforce: false`."
      end

      private

      # Collects all commands across aggregates that declare actor requirements.
      #
      # @return [Array<Hecks::BluebookModel::Structure::Command>] commands with actors
      def actor_protected_commands
        @domain.aggregates.flat_map do |agg|
          agg.commands.select { |cmd| cmd.actors.any? }
        end
      end

      # Checks whether auth middleware (real or sentinel) is on the command bus.
      #
      # @return [Boolean]
      def auth_middleware_registered?
        @command_bus.middleware.any? { |mw| mw[:name] == :auth }
      end
    end
  end
end
