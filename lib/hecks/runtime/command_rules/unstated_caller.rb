require_relative "../caller"
require_relative "../role_shadow"

module Hecks
  module Runtime
    class CommandRules
      # The shadow record of a role-gated command dispatched with no caller bound (ADR 0216).
      #
      # The command runs as before; the would-refuse is counted in the registry's
      # `unstated_caller_log`, keyed by domain, command and origin, so it stays bounded in a
      # long-running process. The count owns the record in Ruby. The first count of a key also
      # writes its `would_refuse_role` line through `RoleShadow`, in the Rust host's `Shadow`
      # wording, when the shadow mode is on; the line renders the count and holds nothing of its
      # own. The one Governance event ADR 0216 decision 4 names as the log's single owner is
      # still to come, and replaces both.
      module UnstatedCaller
        # Where an unbound dispatch came from: a policy or saga reaction, or a door that bound
        # no caller.
        ORIGINS = { true => "reaction", false => "unstated" }.freeze

        # Counts that `command`, which declares a role, ran with no caller bound, and writes the
        # shadow line the first time its key is counted.
        #
        # @param command [Bluebook::Command] the command about to run
        # @param domain [String] name of the command's domain
        # @param verb [String, nil] the command's fully qualified verb; the domain and command
        #   name when the dispatch does not know its aggregate
        # @return [nil]
        def note_unstated_caller(command, domain, verb = nil)
          log = registry&.unstated_caller_log
          return if log.nil?

          key = [domain.to_s, command.hecks_name, ORIGINS.fetch(Caller.reacting?)].freeze
          log[key] = log.fetch(key, 0) + 1
          RoleShadow.note(command, verb || RoleShadow.verb_for(domain, command.hecks_name)) if log[key] == 1
          nil
        end
      end
    end
  end
end
