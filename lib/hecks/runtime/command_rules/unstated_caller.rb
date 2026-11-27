require_relative "../caller"
require_relative "../role_shadow"

module Hecks
  module Runtime
    class CommandRules
      # The record of a role-gated command dispatched by a caller that stated no role, or with no
      # caller bound at all (ADR 0216).
      #
      # Each one is counted in the registry's `unstated_caller_log`, keyed by domain, command and
      # origin, so it stays bounded in a long-running process: `unstated` for the outside caller a
      # door bound as `Caller.unstated`, `reaction` for a policy or saga reaction that ran with no
      # caller, `internal` for the process dispatching for itself. The count owns the record in
      # Ruby. The first count of a key also writes its `would_refuse_role` line through
      # `RoleShadow` when the mode is `shadow`; the line renders the count and holds nothing of its
      # own. The one Governance event ADR 0216 decision 4 names as the log's single owner is still
      # to come, and replaces both.
      module UnstatedCaller
        # Where a dispatch with no stated caller came from.
        ORIGINS = { unstated: "unstated", reaction: "reaction", internal: "internal" }.freeze

        # Counts that `command`, which declares a role, ran with no stated caller, and writes the
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

          key = [domain.to_s, command.hecks_name, ORIGINS.fetch(unstated_origin)].freeze
          log[key] = log.fetch(key, 0) + 1
          RoleShadow.note(command, verb || RoleShadow.verb_for(domain, command.hecks_name)) if log[key] == 1
          nil
        end

        private

        # @return [Symbol] the origin of the dispatch being counted
        def unstated_origin
          return :unstated if Caller.unstated?
          return :reaction if Caller.reacting?

          :internal
        end
      end
    end
  end
end
