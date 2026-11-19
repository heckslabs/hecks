require_relative "../caller"

module Hecks
  module Runtime
    class CommandRules
      # The shadow record of a role-gated command dispatched with no caller bound (ADR 0216).
      #
      # The command runs as before; the would-refuse is counted in the registry's
      # `unstated_caller_log`, keyed by domain, command and origin, so it stays bounded in a
      # long-running process. It is the runtime's `would_refuse_role`, the word the Rust host's
      # `Shadow` mode logs. The count is a stopgap: the Work item role-shadow-report reads it and
      # replaces it with the one Governance event that ADR 0216 decision 4 names as the log's
      # single owner.
      module UnstatedCaller
        # Where an unbound dispatch came from: a policy or saga reaction, or a door that bound
        # no caller.
        ORIGINS = { true => "reaction", false => "unstated" }.freeze

        # Counts that `command`, which declares a role, ran with no caller bound.
        #
        # @param command [Bluebook::Command] the command about to run
        # @param domain [String] name of the command's domain
        # @return [nil]
        def note_unstated_caller(command, domain)
          log = registry&.unstated_caller_log
          return if log.nil?

          key = [domain.to_s, command.hecks_name, ORIGINS.fetch(Caller.reacting?)].freeze
          log[key] = log.fetch(key, 0) + 1
          nil
        end
      end
    end
  end
end
