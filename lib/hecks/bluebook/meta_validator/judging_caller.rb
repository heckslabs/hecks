require_relative "../../runtime/caller"

module Hecks
  module Bluebook
    module MetaValidator
      # The caller a judge states when it offers a declaration to the language declared in itself
      # (ADR 0216).
      #
      # Every role-gated command of bluebook.bluebook declares `role "Language"`, and every one of
      # the world, port, adapter and translation languages declares `role "Deployment"`. A judge
      # dispatches as the role its language declares, so loading a file reaches the language as a
      # caller who holds that role, whoever loads it: neither an outside caller who stated no role
      # nor a launcher line's own role is checked against the language's commands. Dispatched as a
      # caller who states no role, the same load is refused in the `role_unstated` wording. The
      # Hecks world grants both roles to its launcher's caller (`caller_roles`), as it grants every
      # other role a line runs as.
      module JudgingCaller
        # The role every role-gated command of bluebook.bluebook declares.
        LANGUAGE = "Language".freeze
        # The role every role-gated command of the world, port, adapter and translation languages
        # declares.
        DEPLOYMENT = "Deployment".freeze

        module_function

        # Runs the block as a caller who states `role`, with no actor, restoring the caller bound
        # around it.
        #
        # @param role [String] `LANGUAGE` or `DEPLOYMENT`
        # @yield the judge's dispatches
        # @return [Object] the block's result
        def as(role, &) = Runtime::Caller.as(role: role, &)

        # Runs the block as a caller who states `LANGUAGE`.
        #
        # @yield the dispatches into bluebook.bluebook
        # @return [Object] the block's result
        def as_language(&) = as(LANGUAGE, &)
      end
    end
  end
end
