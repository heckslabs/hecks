module Hecks
  module Fuzzing
    module Replay
      # Reads, before a role-gated dispatch by an identified caller, the grants that actor holds
      # through the authorization provider's own declared `assignments` verb, so the outcome can be
      # compared with what the dispatch actually did.
      module RoleCheck
        module_function

        # The caller and live grants for one step; nil for any step with no identified caller, no
        # declared role, or no authorization provider (those are string-compared, not grant-checked).
        #
        # @param runtime [Hecks::Runtime] the booted runtime the step will dispatch against
        # @param step [Hash] a replay step, string-keyed
        # @return [Hash, nil] `verb:`, `role:`, `actor_id:` and `grants:` (each `role:`, `ended:`)
        def build(runtime, step)
          return nil unless step["role"] && step["actor_id"]

          domain, command = command_of(runtime, step["verb"])
          return nil unless command && governed?(runtime, domain, command)

          { verb: step["verb"], role: command.role.to_s, actor_id: step["actor_id"].to_s,
            grants: grants_for(runtime.registry, step["actor_id"]) }
        rescue StandardError
          nil
        end

        # The `[domain, command]` an aggregate-level verb names; the command is nil when none does.
        def command_of(runtime, verb)
          domain, aggregate_name, command_name = Naming.split_verb(verb)
          [domain, runtime.registry.bluebook(domain)&.aggregate(aggregate_name)&.command(command_name)]
        end

        # Whether the command declares a role and its domain has an authorization provider.
        def governed?(runtime, domain, command)
          !command.role.to_s.empty? && !runtime.registry.authorization_provider_for(domain).nil?
        end

        # The actor's assignments, read through the verb the provider declares for `assignments`.
        def grants_for(registry, actor_id)
          provider = registry.authorization_providers.first
          verb = provider.provided_verb(Bluebook::Capabilities::AUTHORIZATION, :assignments)
          rows = Runtime::Dispatcher.new(registry).query(verb, actor_id: { value: actor_id.to_s })
          rows.map { |row| { role: row[:role_name][:value], ended: !row[:ends_at].nil? } }
        end
      end
    end
  end
end
