module Hecks
  module Bluebook
    module ModelCheck
      # The checks over a policy: reactions to events nothing emits, triggers that name no
      # command, and the relationship a cross-domain reaction claims against its hecksagon.
      module PolicyChecks
        # Runs every same-domain policy check, or defers to
        # cross_domain_policy_findings for a cross-domain policy.
        def policy_findings(bluebook, policy, hecksagon, known_domains, global_emitted_events = nil)
          return cross_domain_policy_findings(policy, hecksagon, known_domains) if policy.target_domain

          [
            deaf_policy_finding(policy, emitted_events(bluebook), global_emitted_events),
            policy.asks? ? nil : unknown_trigger_finding(bluebook, policy),
            ask_finding(bluebook, policy)
          ].compact
        end

        # `policy.event_name`, not `bare` — an aggregate-scoped on_event carries a
        # "." qualifier bare doesn't strip. `global_emitted_events` is a fallback for
        # a translates reaction, whose whole point is reacting to a foreign event.
        def deaf_policy_finding(policy, emitted, global_emitted_events)
          return if emitted.include?(policy.event_name) || global_emitted_events&.include?(policy.event_name)

          Finding.new(kind: :deaf_policy, severity: :error, subject: policy.name,
                      message: "on #{policy.on_event.inspect}, which no command in this domain emits")
        end

        # Completed to the same FQN verbs_of builds, then compared as a parsed
        # triple — not a string — so a port-operation trigger's spelling matches
        # the same way an entity command's does (see handler_findings).
        def unknown_trigger_finding(bluebook, policy)
          qualified = Naming.split_verb("#{bluebook.name}::#{policy.trigger_command}")
          return if qualified && triggerable_verbs(bluebook).include?(qualified)

          Finding.new(kind: :unknown_trigger, severity: :error, subject: policy.name,
                      message: "trigger #{policy.trigger_command.inspect} resolves to no command " \
                               "this domain declares")
        end

        # `attaches` is a Shared Kernel relationship (X merges in, no boundary);
        # `across` is Customer/Supplier (real cross-Lambda RPC). This checks the choice
        # between them instead of leaving it as an unenforced comment. (ADR 0025)
        def cross_domain_policy_findings(policy, hecksagon, known_domains)
          return expected_undelivered_findings(policy, hecksagon, known_domains) if policy.expect_undelivered
          # No sibling hecksagon loaded — nothing to check a relationship against.
          return [] unless hecksagon

          [relationship_finding(policy, hecksagon), unknown_target_finding(policy, known_domains)].compact
        end

        # @return [Finding, nil] the finding for an `across` target that is both attached and
        #   dispatched to, or for one the hecksagon never acknowledges; `nil` when neither
        def relationship_finding(policy, hecksagon)
          target = policy.target_domain
          return contradictory_relationship_finding(policy, target) if hecksagon.attaches?(target)
          return unless hecksagon.subscriptions.none? { |subscribed| Naming.qualifier(subscribed) == target }

          # Checked here at model-check time; subscribe itself is never routed at
          # runtime (see hecksagon.md's own "checked, not routed" section).
          Finding.new(kind: :unacknowledged_relationship, severity: :error, subject: policy.name,
                      message: "across #{target.inspect} declares a Customer/Supplier " \
                               "relationship, but nothing in this hecksagon records the " \
                               "expectation — add subscribe \"#{target}.SomeEvent\" for what " \
                               "you expect back from it, or attaches #{target.inspect} to " \
                               "attach it in-process instead")
        end

        # Shared Kernel and Customer/Supplier are mutually exclusive claims about
        # the same target — declaring both means either a pointless RPC to a
        # domain already local, or an attaches that isn't doing its job.
        def contradictory_relationship_finding(policy, target)
          Finding.new(kind: :contradictory_relationship, severity: :error, subject: policy.name,
                      message: "across #{target.inspect} dispatches over RPC (Customer/Supplier), " \
                               "but this hecksagon also attaches #{target.inspect} (Shared " \
                               "Kernel) — #{target} is already loaded in-process here, so the two " \
                               "relationship declarations contradict each other for the same " \
                               "target domain")
        end

        # A heuristic, not proof: an external hecks consumer's own domain lives in a
        # repo this corpus scan can't see, so "unknown here" isn't necessarily a typo.
        # A domain undefined on purpose declares so via expect_undelivered instead.
        def unknown_target_finding(policy, known_domains)
          target = policy.target_domain
          return unless known_domains && !known_domains.include?(target)

          Finding.new(kind: :unknown_target_domain, severity: :error, subject: policy.name,
                      message: "across #{target.inspect} names a domain nowhere in the corpus " \
                               "this check has booted — a typo, or a target intentionally never " \
                               "reached, which the policy itself declares with " \
                               "across #{target.inspect}, expect_undelivered: true")
        end

        # Holds an expect_undelivered declaration to its word: the two findings an
        # unreachable target would otherwise raise are suppressed (that's the point of
        # the declaration), but if the target turns out reachable after all, the stale
        # declaration itself is now the error.
        def expected_undelivered_findings(policy, hecksagon, known_domains)
          target  = policy.target_domain
          reached = delivery_routes(target, hecksagon, known_domains)
          return [] if reached.empty?

          [Finding.new(kind: :stale_undelivered_expectation, severity: :error, subject: policy.name,
                       message: "across #{target.inspect}, expect_undelivered: true — but #{reached.join(" and ")}, " \
                                "so the reaction can be delivered after all; drop expect_undelivered: or remove " \
                                "what reaches #{target}")]
        end

        # @return [Array<String>] each way `target` turns out reachable, in the order they are told
        def delivery_routes(target, hecksagon, known_domains)
          routes = []
          routes << "#{target} is a domain this corpus boots" if known_domains&.include?(target)
          routes.concat(hecksagon_routes(target, hecksagon)) if hecksagon
          routes
        end

        # @return [Array<String>] how the hecksagon reaches `target`: it attaches or subscribes
        def hecksagon_routes(target, hecksagon)
          routes = []
          routes << "this hecksagon attaches #{target.inspect}" if hecksagon.attaches?(target)
          if hecksagon.subscriptions.any? { |subscribed| Naming.qualifier(subscribed) == target }
            routes << "this hecksagon subscribes to #{target}"
          end
          routes
        end
      end
    end
  end
end
