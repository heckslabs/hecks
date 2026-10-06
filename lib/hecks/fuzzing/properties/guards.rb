module Hecks
  module Fuzzing
    module Properties
      # Guard and authorization properties over a replayed history: refusals name declared rules,
      # tenant scoping holds, and guard violations are refused.
      module Guards
        # Checks tenant-scoped query answers and refusals against TenantScope.apply's contract.
        #
        # Uses hand-built fixtures: the only corpus query declaring `authorize` takes no
        # attributes, so the generator cannot supply a `tenant:`.
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true if every answer and refusal agrees with the contract
        def authorize_scopes_or_refuses(history)
          bluebooks = history.fetch(:bluebooks)

          offenders = history.fetch(:queries).filter_map do |asked|
            next unless asked[:query].is_a?(String) && asked[:query].include?("::")

            declared = query_for_verb(bluebooks, asked[:query])
            authorization = declared&.authorization
            tenant = authorization&.tenant&.to_sym
            next unless tenant

            args = asked[:args] || {}
            tenant_given = args.key?(tenant)

            if asked[:error]
              next if tenant_given
              next if asked[:error].to_s.include?("declares authorize with tenant: #{tenant}")

              "#{asked[:query]} #{args.inspect} refused with no #{tenant}: given, but not with the declared " \
                "tenant_required wording (#{asked[:error]})"
            elsif !tenant_given
              "#{asked[:query]} #{args.inspect} answered successfully with no #{tenant}: given, but #{declared.name} " \
                "declares authorize with tenant: #{tenant}"
            else
              wanted = args[tenant].to_s
              mismatched = asked[:rows].find do |row|
                Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, tenant)).to_s != wanted
              end
              next unless mismatched

              "#{asked[:query]} #{args.inspect} answered a row whose #{tenant} disagrees with the given " \
                "#{wanted.inspect}: #{mismatched.inspect}"
            end
          end

          offenders.empty? || offenders.join("; ")
        end

        # Raised classes that mark a guard refusal; the message alone cannot tell it from
        # the other "X refused — Y" wordings.
        GUARD_REFUSAL_KINDS = %w[Hecks::Runtime::GivenNotMet Hecks::Runtime::EnsuresNotMet].freeze

        # Checks that every given/ensures refusal quotes a description its command declares.
        def guard_refusals_are_declared(history)
          bluebooks = history.fetch(:bluebooks)

          offenders = history.fetch(:refusals).filter_map do |refusal|
            next unless GUARD_REFUSAL_KINDS.include?(refusal[:kind])

            match = refusal[:error].to_s.match(/\A(.+) refused — (.+)\z/)
            next "#{refusal[:verb]} raised #{refusal[:kind]} with unparseable message #{refusal[:error].inspect}" unless match

            command = command_for_verb(bluebooks, refusal[:verb])
            next "#{refusal[:verb]} raised #{refusal[:kind]}, but no declared command resolves that verb" unless command

            declared = effective_guard_descriptions(bluebooks, refusal[:verb], command)
            next if declared.include?(match[2])

            "#{refusal[:verb]} refused — #{match[2].inspect} — but #{command.hecks_name} declares no given " \
              "or ensures with that description (it declares #{declared.inspect})"
          end

          offenders.empty? || offenders.join("; ")
        end

        # Checks that no stored record references a record carrying a different tenant value.
        #
        # Commands cannot declare `authorize`, so nothing refuses a cross-tenant write.
        # Tenants compare via Query::InMemory.comparable: value objects with different
        # declared names are unequal under Value#== even for the same tenant.
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
        def commands_respect_tenant_scope(history)
          bluebooks = history.fetch(:bluebooks)
          instances = history.fetch(:instances)

          offenders = instances.flat_map do |key, state|
            domain_name    = key.split("::").first
            aggregate_name = key.split("::").last.split("#").first
            aggregate      = bluebooks[domain_name]&.aggregate(aggregate_name)
            next [] unless aggregate

            own_tenant_field = tenant_field_for(aggregate)
            next [] unless own_tenant_field && state.key?(own_tenant_field)

            own_tenant = Ports::Query::InMemory.comparable(state[own_tenant_field])

            aggregate.attributes.filter_map do |attribute|
              next unless attribute.type.is_a?(Bluebook::Reference)

              target = bluebooks[domain_name]&.aggregate(attribute.type.target_name)
              target_tenant_field = target && tenant_field_for(target)
              next unless target_tenant_field

              target_id = state[attribute.name]
              next unless target_id

              target_state = instances["#{domain_name}::#{target.name}##{target_id}"]
              next unless target_state&.key?(target_tenant_field)

              target_tenant = Ports::Query::InMemory.comparable(target_state[target_tenant_field])
              next if target_tenant == own_tenant

              "#{key} (#{own_tenant_field}: #{own_tenant.inspect}) references #{attribute.name}: #{target_id.inspect}, " \
                "but #{domain_name}::#{target.name}##{target_id} carries #{target_tenant_field}: " \
                "#{target_tenant.inspect} — a cross-tenant write nothing refused"
            end
          end

          offenders.empty? || offenders.join("; ")
        end

        # The field named by `authorize ..., tenant:` on any of the aggregate's queries, or nil.
        def tenant_field_for(aggregate)
          authorization = aggregate.queries.filter_map(&:authorization).find(&:tenant)
          authorization&.tenant&.to_sym
        end

        # A command's own guard descriptions plus those of every command it delegates to.
        #
        # A delegating door refuses with its target's words, so both sets count. Resolved
        # against the full `bluebooks` map: a verb's domain is not always `history[:bluebook]`.
        def effective_guard_descriptions(bluebooks, verb, command)
          own = command.guard_descriptions
          delegated = command.mutations.select { |m| m.op == :delegate }.flat_map do |delegation|
            domain, aggregate_name, = Naming.split_verb(verb)
            target = command_for_verb(bluebooks, "#{domain}::#{aggregate_name}.#{delegation.target}")
            target ? target.guard_descriptions : []
          end
          own + delegated
        end

        # Resolves a dispatched verb to the declared command it names, or nil.
        def command_for_verb(bluebooks, verb)
          domain, aggregate_name, command_path = Naming.split_verb(verb)
          return nil unless command_path

          bluebook = bluebooks[domain]
          return nil unless bluebook

          aggregate = bluebook.aggregate(aggregate_name)
          return nil unless aggregate

          if command_path.include?(".")
            entity_name, sub = command_path.split(".", 2)
            entity = aggregate.entities.find { |e| e.hecks_name == entity_name }
            entity&.command(sub)
          else
            aggregate.command(command_path)
          end
        end

        # Recomputes enforce_givens/enforce_lifecycle_guard against Replay's pre-dispatch
        # snapshot and compares the result with what the real dispatch did.
        #
        # Catches a guard that silently stopped firing, which never appears in
        # history[:refusals]. Any other refusal class, or a success, counts as "did not fire".
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true if the recomputed and actual outcomes agree for every check
        def lifecycle_guard_and_given_violations_are_refused(history)
          offenders = history.fetch(:guard_checks).filter_map do |check|
            next if check[:recomputed_refused] == check[:actual_refused]

            "#{check[:verb]} — independently recomputing enforce_givens/enforce_lifecycle_guard against the " \
              "pre-dispatch state says #{check[:recomputed_refused] ? "refused (#{check[:recomputed_kind]})" : "admitted"}, " \
              "but the real dispatch #{check[:actual_refused] ? "refused (#{check[:actual_kind]})" : "admitted it"}"
          end

          offenders.empty? || offenders.join("; ")
        end
      end
    end
  end
end
