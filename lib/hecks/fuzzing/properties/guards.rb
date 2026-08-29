module Hecks
  module Fuzzing
    module Properties
      # Guard/authorization properties: every given/ensures refusal a run
      # actually raised names a rule the refusing command actually declares,
      # a scope-authorized answer (or its refusal) is correctly worded, and
      # a lifecycle guard's own violation is refused rather than silently
      # admitted.

      # Holds authorize_scopes_or_refuses, guard_refusals_are_declared, and
      # lifecycle_guard_and_given_violations_are_refused, plus the shared
      # verb-to-declaration lookups (#command_for_verb,
      # #effective_guard_descriptions) each resolves a refusal against.
      module Guards
        # `Query#options`' OTHER HALF — TenantScope.apply's own contract
        # (tenant_scope.rb), independently restated as a property rather
        # than exercised only through whatever the generator happens to
        # try. NOT closed by the generator here on purpose: SafeDepositBox.
        # Rented — the only real corpus query declaring `authorize` at
        # all — declares ZERO attributes of its own, so StepBuilder#args_for
        # always hands it `{}` and TenantScope.apply refuses every
        # generated attempt, unconditionally (confirmed: no successful ask
        # against an authorize-bearing query reaches this property via the
        # standard battery today). Extending the generator to invent a
        # `tenant:` value ran into a separate, real finding along the way —
        # SafeDepositBox is COMPOSITE-identified (`identified_by` is nil
        # for it — Runtime::Identified#derive_identity), so the generator's
        # existing `known_ids` pool (keyed by `aggregate.identified_by ||
        # "id"`) tracks a stray, never-real scalar for it rather than its
        # true `branch_code`+`box_number` pair — a second, narrower
        # generator gap this property does not attempt to fix, since fixing
        # it well enough to trust a generated `tenant:` value would be the
        # heavier, "benefits every future property" path the plan itself
        # names as the alternative. Hand-built fixtures close the real
        # claim directly instead: faster, narrower, and correct either way,
        # since TenantScope.apply's contract is identical regardless of
        # where a `tenant:` arg came from.
        #
        # Two claims, matching TenantScope.apply's own two branches: every
        # SUCCESSFUL answer's own tenant field agrees with the tenant arg
        # given (the WhereClause TenantScope injects is a Symbol reference
        # into args, resolved dynamically — this checks the OUTCOME, not
        # re-deriving that resolution) ; every ask MISSING a required
        # tenant: refuses with the declared wording, never succeeds. A
        # refusal for an unrelated reason with the tenant arg present is
        # not this property's claim either way — skipped, not graded.
        # The three mutually exclusive outcomes ("refused, was it for the
        # declared reason?" / "succeeded without a tenant that was
        # required?" / "succeeded with a tenant, does every row actually
        # agree with it?") map exactly onto TenantScope.apply's own two
        # branches, per the comment above — splitting them into separate
        # methods would mean threading `asked`, `tenant`, `args`, and
        # `declared` out to each one for no gain, since none of the three
        # branches shares logic with the others beyond that shared setup.
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
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

        # EVERY GIVEN/ENSURES REFUSAL A RUN ACTUALLY RAISED NAMES A RULE
        # THE COMMAND ACTUALLY DECLARES. `GivenNotMet`/`EnsuresNotMet` both
        # quote their guard's own `description` verbatim
        # (command_rules/admissibility.rb: `"#{command.hecks_name} refused
        # — #{given.description}"`) — the SAME text `behavior.bluebook`'s
        # own `Rule`/Command.Ensure hold as `Rule#description`, so a
        # refusal whose quoted text is not among the refusing command's
        # OWN `guard_descriptions` (Behaviour::Command, both givens and
        # ensures) is either a stale message surviving a renamed rule, a
        # rule firing against the wrong command's own guard set, or the
        # wording drifting out from under the declaration it is supposed
        # to quote — banking's own 128 status givens (customer/account
        # guards, some through a cross-aggregate dereference) are exactly
        # the surface this exists to hold to its word.
        #
        # `kind:` is what tells a guard refusal apart from the FOUR other
        # `RefusalWording` templates sharing the identical "X refused — Y"
        # shape (LifecycleRefused/transition_blocked, both TypeMismatch
        # object-reference templates, Unauthorized/role_mismatch) — see
        # Replay's own comment at the refusal rescue site. Pattern-matching
        # the string alone would confuse a guard's own wording with any of
        # those; the raised class does not.
        GUARD_REFUSAL_KINDS = %w[Hecks::Runtime::GivenNotMet Hecks::Runtime::EnsuresNotMet].freeze

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

        # A DECLARED PROCESS MANAGER'S OWN COMMAND — `command.hecks_name`,
        # or an entity's own if the verb's second component is itself
        # dotted (`Aggregate.Entity.Command`, the same two shapes
        # `Dispatcher#dispatch` itself branches on). Shared by the guard
        # property above and available for anything else that needs to go
        # from a replayed verb back to its declaration.
        #
        # RESOLVED AGAINST `bluebooks` (the FULL map, `history[:bluebooks]`
        # — every loaded domain, keyed by name), never a single assumed
        # bluebook: a verb names its OWN domain (`Naming.split_verb`'s
        # first element), and that domain is not always the one Replay
        # happens to expose as `history[:bluebook]`. A fuzz run against
        # `lib/hecks/grammar` (Expression + Translation, in load
        # order) found this the hard way — every `Translation::Map.Seal`
        # refusal read as "no declared command resolves that verb" purely
        # because `history[:bluebook]` was Expression, not Translation; the
        # refusal was real, this property's own domain resolution was not.
        # A DELEGATING DOOR REFUSES WITH ITS TARGET'S OWN WORDS. `delegates_to`
        # (CommandBuilder#delegates_to_impl) hands the whole dispatch to one
        # entity command, and that command's given is what refuses — raised
        # back through the door, in the door's name (chess: `Game.MoveKnight
        # refused — "it is that color's turn"`, a given Knight.Move declares
        # and MoveKnight, a pure passthrough, never could). Read the door's
        # own guards first, then every delegation target's; an offence is
        # only a description NEITHER declares. Found live mining chess's
        # history: every refused move through a door read as undeclared.
        def effective_guard_descriptions(bluebooks, verb, command)
          own = command.guard_descriptions
          delegated = command.mutations.select { |m| m.op == :delegate }.flat_map do |delegation|
            domain, aggregate_name, = Naming.split_verb(verb)
            target = command_for_verb(bluebooks, "#{domain}::#{aggregate_name}.#{delegation.target}")
            target ? target.guard_descriptions : []
          end
          own + delegated
        end

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

        # `guard_refusals_are_declared`'s OWN OPPOSITE DIRECTION. That
        # property is passive and one-directional — for a refusal that
        # ALREADY HAPPENED, is the quoted text real declared text? It says
        # nothing about a guard that should have refused and silently did
        # not — a call site that stopped calling enforce_givens/enforce_
        # lifecycle_guard would never appear in history[:refusals] at all,
        # invisible to that property by construction.
        #
        # This one calls Admissibility#enforce_givens (which itself folds
        # in #enforce_lifecycle_guard whenever `declaring:` is passed)
        # DIRECTLY, against Replay's own pre-dispatch snapshot
        # (history[:guard_checks], one bounded, additive extension — see
        # that file's own comment at the capture site) — an independent
        # recomputation, not grading production against itself, the same
        # "two engines, compared" shape query_answers_match_reference and
        # the fan-out oracle already establish. `recomputed_refused`
        # (Replay's own call, made live, before this step's real dispatch
        # could mutate anything a cross-aggregate given dereferences) is
        # compared against `actual_refused` (GivenNotMet/LifecycleRefused
        # specifically — Replay's own comment on GUARD_REFUSAL_CLASSES
        # explains why ANY other refusal class, or an outright success,
        # both count as "the guard did not fire," since enforce_givens
        # runs FIRST in DISPATCH_ORDER).
        #
        # Aggregate#preconditions closes for free alongside this — a
        # no-block `given` reference (CommandBuilder#given) pushes the
        # SAME Given struct object `enforce_givens` already iterates
        # command.givens for, so there is no separate runtime path a
        # property could exercise beyond what this already reaches.
        # Entity#preconditions closes the identical way, one level down
        # (ADR 0028) — a piece's own bare `given` reference pushes the
        # SAME Given struct onto ITS OWN referencing command's givens,
        # so LedgerEntry's own Amend/Reverse (banking) already exercise
        # this through the exact mechanism above, no separate path.
        #
        # Real targets: Account.Debit/CloseAccount (`from:` guards),
        # Credit/Debit (the named-once `given("customer is active")`
        # precondition) — FreezeAccount deliberately references the
        # DIFFERENT named precondition `"customer is not closed"` instead
        # (a suspended customer must still be freezable), so it is not a
        # `"customer is active"` example, just the same MECHANISM.
        def lifecycle_guard_and_given_violations_are_refused(history)
          offenders = history.fetch(:guard_checks).filter_map do |check|
            next if check[:recomputed_refused] == check[:actual_refused]

            "#{check[:verb]} — independently recomputing enforce_givens/enforce_lifecycle_guard against the " \
              "pre-dispatch state says #{check[:recomputed_refused] ? "refused (#{check[:recomputed_kind]})" : 'admitted'}, " \
              "but the real dispatch #{check[:actual_refused] ? "refused (#{check[:actual_kind]})" : 'admitted it'}"
          end

          offenders.empty? || offenders.join("; ")
        end
      end
    end
  end
end
