require_relative "tenant_scope"

module Hecks
  module Fuzzing
    module Properties
      # Guard and authorization properties over a replayed history: refusals name declared rules,
      # tenant scoping holds, and guard violations are refused.
      module Guards
        include TenantScope

        # Checks tenant-scoped query answers and refusals against TenantScope.apply's contract.
        #
        # Uses hand-built fixtures: the only corpus query declaring `authorize` takes no
        # attributes, so the generator cannot supply a `tenant:`.
        #
        # @param history [Hash] a replayed history as returned by `Replay.call`
        # @return [true, String] true if every answer and refusal agrees with the contract
        def authorize_scopes_or_refuses(history)
          bluebooks = history.fetch(:bluebooks)
          offenders = history.fetch(:queries).filter_map { |asked| authorize_offense(bluebooks, asked) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one query answer that breaks the tenant contract, or nil.
        def authorize_offense(bluebooks, asked)
          declared = declared_query(bluebooks, asked)
          tenant = query_tenant(declared)
          return unless tenant

          args = asked[:args] || {}
          return refusal_offense(asked, args, tenant) if asked[:error]
          return unscoped_answer_offense(asked, args, tenant, declared) unless args.key?(tenant)

          mismatched_row_offense(asked, args, tenant)
        end

        def declared_query(bluebooks, asked)
          query_for_verb(bluebooks, asked[:query]) if asked[:query].is_a?(String) && asked[:query].include?("::")
        end

        def query_tenant(declared)
          authorization = declared&.authorization
          authorization&.tenant&.to_sym
        end

        def refusal_offense(asked, args, tenant)
          return if args.key?(tenant)
          return if asked[:error].to_s.include?("declares authorize with tenant: #{tenant}")

          "#{asked[:query]} #{args.inspect} refused with no #{tenant}: given, but not with the declared " \
            "tenant_required wording (#{asked[:error]})"
        end

        def unscoped_answer_offense(asked, args, tenant, declared)
          "#{asked[:query]} #{args.inspect} answered successfully with no #{tenant}: given, but #{declared.name} " \
            "declares authorize with tenant: #{tenant}"
        end

        def mismatched_row_offense(asked, args, tenant)
          wanted = args[tenant].to_s
          mismatched = asked[:rows].find do |row|
            Ports::Query::InMemory.comparable(QuerySpecification::FieldPath.dig(row, tenant)).to_s != wanted
          end
          return unless mismatched

          "#{asked[:query]} #{args.inspect} answered a row whose #{tenant} disagrees with the given " \
            "#{wanted.inspect}: #{mismatched.inspect}"
        end

        # Raised classes that mark a guard refusal; the message alone cannot tell it from
        # the other "X refused — Y" wordings.
        GUARD_REFUSAL_KINDS = %w[Hecks::Runtime::GivenNotMet Hecks::Runtime::EnsuresNotMet].freeze

        # Checks that every given/ensures refusal quotes a description its command declares.
        def guard_refusals_are_declared(history)
          bluebooks = history.fetch(:bluebooks)
          offenders = history.fetch(:refusals).filter_map { |refusal| guard_refusal_offense(bluebooks, refusal) }
          offenders.empty? || offenders.join("; ")
        end

        # The message for one guard refusal whose quoted description is not declared, or nil.
        def guard_refusal_offense(bluebooks, refusal)
          return unless GUARD_REFUSAL_KINDS.include?(refusal[:kind])

          match = refusal[:error].to_s.match(/\A(.+) refused — (.+)\z/)
          return "#{refusal[:verb]} raised #{refusal[:kind]} with unparseable message #{refusal[:error].inspect}" unless match

          command = command_for_verb(bluebooks, refusal[:verb])
          return "#{refusal[:verb]} raised #{refusal[:kind]}, but no declared command resolves that verb" unless command

          undeclared_guard_offense(bluebooks, refusal, match[2], command)
        end

        def undeclared_guard_offense(bluebooks, refusal, description, command)
          declared = effective_guard_descriptions(bluebooks, refusal[:verb], command)
          return if declared.include?(description)

          "#{refusal[:verb]} refused — #{description.inspect} — but #{command.hecks_name} declares no given " \
            "or ensures with that description (it declares #{declared.inspect})"
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

          aggregate = bluebooks[domain]&.aggregate(aggregate_name)
          return nil unless aggregate

          command_in(aggregate, command_path)
        end

        # The command a dotted or plain path names under `aggregate`: an entity's own command
        # when the path names an entity.
        def command_in(aggregate, command_path)
          return aggregate.command(command_path) unless command_path.include?(".")

          entity_name, sub = command_path.split(".", 2)
          aggregate.entities.find { |e| e.hecks_name == entity_name }&.command(sub)
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
