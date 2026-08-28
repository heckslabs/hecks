require "set"

module Hecks
  module Bluebook
    # Lightweight formal methods over the IR — the same family as TLA+/
    # Alloy/P: every lifecycle is a declared finite state machine and
    # every process manager a declared protocol, and BOTH are already
    # data, not code, so they can be MODEL-CHECKED rather than merely
    # executed. Static analysis only — no bluebook boots twice, no
    # runtime is touched — over what meta_validator/judge.rb and the
    # builders' own `validate!` methods leave uncovered (an undeclared
    # transition target, a dispatch to nowhere, a compensation nothing
    # can ever reach).
    #
    # THE RARE PROPERTY THIS RESTS ON: the model IS the implementation.
    # A checker over TLA+ verifies a SPEC a human keeps in sync with
    # code by hand ; this verifies the same IR the runtime dispatches
    # against, so there is no second copy to drift.
    module ModelCheck
      Finding = Struct.new(:kind, :severity, :subject, :message, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{kind.to_s.ljust(20)} #{subject}  —  #{message}"
      end

      # A FINDING SHIPPED, NOT SILENCED — the coverage-gate idiom, empty
      # allowlists enforced BOTH directions (spec/model_check_spec.rb holds
      # this exact table: an error the checker reports and this does not
      # name is a regression, an entry the checker no longer reports is
      # stale and must be deleted). bin/model_check reads this same
      # constant, so the tool and the spec can never drift apart.
      #
      # "banking"/ExternalSettlement — found on the first real run:
      # ExternalSettlement declares `ends_on "ExternalTransferSent"`, and
      # ExternalTransfer.Send genuinely emits it — the event is real, and
      # the AGGREGATE reaches "sent" (its own, separate lifecycle) — but
      # the SAGA'S protocol has no `on "ExternalTransferSent"` handler, so
      # its own `state "sent"` is unreachable through the chain the
      # checker walks, and the saga's own bookkeeping (saga_log, ends_on)
      # never closes it. Real domain activity is unaffected; the saga's
      # OWN tracking of it is not. Left named rather than redesigning a
      # corpus fixture that is not this checker's to redesign.
      # S7, ADR 0025 — the ExternalSettlement finding this used to
      # allowlist is GONE, not just quieted: its "sent" state was a
      # `state "x"` line never named by any handler's own from:/to:, a
      # pure declaration-drift artifact. States are DERIVED from the
      # transitions that name them now (ProcessManagerBuilder#derived_
      # states), so a state nothing ever transitions into or out of no
      # longer exists to be unreachable — the finding this allowlisted
      # cannot occur any more, by construction.
      #
      # "banking"/NotifyOnClosure, FlagKeyReturn — real, confirmed
      # findings, not bugs to fix. `across "Notifications"` names a
      # domain that does not exist anywhere in this repo — no
      # Notifications bluebook, no hecksagon, nothing to `uses_framework`
      # or `subscribe` to. This is deliberate: `spec/runtime/policy_spec.
      # rb` (a test literally named "records a reaction it cannot
      # deliver rather than swallowing it") and `lib/hecks/runtime/
      # errors.rb`'s own `UnknownVerb` comment both treat "target domain
      # not loaded" as the EXPECTED outcome for it — Notifications is
      # used on purpose to exercise the undelivered-reaction runtime
      # path, not left half-built. There is no real `subscribe` line to
      # add (no event of Notifications' own to name) and no real domain
      # to point `uses_framework` at.
      ALLOWED_FINDINGS = {
        "banking" => [
          [:unacknowledged_relationship, "NotifyOnClosure"],
          [:unknown_target_domain, "NotifyOnClosure"],
          [:unacknowledged_relationship, "FlagKeyReturn"],
          [:unknown_target_domain, "FlagKeyReturn"]
        ]
      }.freeze

      module_function

      # `hecksagon:`/`known_domains:` — both optional, both `nil`-safe
      # (every existing caller with no sibling hecksagon, or checking one
      # domain in isolation, behaves exactly as before). `hecksagon` is
      # THIS bluebook's own sibling wiring file, if the caller loaded one
      # (see `emitted_events`'s own comment on why a caller that didn't
      # simply finds none, correctly). `known_domains` is the caller's
      # OWN corpus-wide view — every bluebook/hecksagon name it has
      # booted anywhere, across every domain it has looked at, not just
      # this one — used only to catch a typo'd `across`/`uses_framework`
      # target; see `cross_domain_policy_findings`'s own comment for why
      # this can only ever be a corpus-scoped heuristic, never a general
      # correctness guarantee.
      def call(bluebook, hecksagon: nil, known_domains: nil)
        findings = []
        bluebook.aggregates.each do |aggregate|
          findings.concat(lifecycle_findings(aggregate, aggregate))
          aggregate.entities.each { |entity| findings.concat(lifecycle_findings(aggregate, entity)) }
        end
        bluebook.process_managers.each { |pm| findings.concat(saga_findings(bluebook, pm)) }
        bluebook.policies.each { |policy| findings.concat(policy_findings(bluebook, policy, hecksagon, known_domains)) }
        findings
      end

      # ── lifecycles (aggregate AND entity — a piece may declare one too) ──

      def lifecycle_findings(aggregate, declaring)
        lifecycle = declaring.lifecycle
        return [] unless lifecycle

        subject = declaring.equal?(aggregate) ? aggregate.hecks_name : "#{aggregate.hecks_name}::#{declaring.hecks_name}"
        commands = Array(declaring.commands).map(&:hecks_name)

        findings = []
        findings.concat(unknown_transition_commands(lifecycle, commands, subject))

        full = full_states(lifecycle)
        reached = reachable_states(lifecycle)

        (full - reached.to_a).each do |state|
          findings << Finding.new(kind: :unreachable_state, severity: :error, subject: subject,
                                  message: "#{state.inspect} is declared (in a transition's from: or target) " \
                                           "but no path from #{lifecycle.default.inspect} ever reaches it")
        end

        lifecycle.transitions.each do |command, transition|
          next unless transition.constrained?
          next if Array(transition.from).any? { |source| reached.include?(source) }

          findings << Finding.new(kind: :dead_transition, severity: :error, subject: subject,
                                  message: "#{command} from #{Array(transition.from).inspect} can never fire — " \
                                           "none of those states is ever reached")
        end

        any_unconstrained = lifecycle.transitions.any? { |_, t| !t.constrained? }
        (reached - terminal_exempt(lifecycle)).each do |state|
          next if any_unconstrained
          next if lifecycle.transitions.any? { |_, t| t.constrained? && Array(t.from).include?(state) }

          findings << Finding.new(kind: :stuck_state, severity: :warning, subject: subject,
                                  message: "#{state.inspect} is reached but no transition ever leaves it — " \
                                           "fine if that is meant to be terminal")
        end

        findings
      end

      def unknown_transition_commands(lifecycle, commands, subject)
        lifecycle.transitions.filter_map do |command, _transition|
          next if commands.include?(command)

          Finding.new(kind: :unknown_command, severity: :error, subject: subject,
                      message: "a transition names #{command.inspect}, which this construct declares no command for")
        end
      end

      # default, every declared target, and every declared from — a
      # from-only state (declared nowhere as a target) is real and is
      # exactly the hole `Lifecycle#states` leaves: it answers default
      # plus targets only.
      def full_states(lifecycle)
        (
          [lifecycle.default] +
          lifecycle.transitions.map { |_, t| t.target } +
          lifecycle.transitions.flat_map { |_, t| Array(t.from) }
        ).uniq
      end

      # Least fixpoint from the default state: an UNCONSTRAINED
      # transition always fires, from wherever the machine is ; a
      # constrained one fires once any of its named sources is reached.
      def reachable_states(lifecycle)
        reached = Set.new([lifecycle.default])
        loop do
          grown = false
          lifecycle.transitions.each do |_, transition|
            next if reached.include?(transition.target)
            next if transition.constrained? && Array(transition.from).none? { |source| reached.include?(source) }

            reached << transition.target
            grown = true
          end
          break unless grown
        end
        reached
      end

      # A state with no OUTGOING declared path at all is exempt from the
      # stuck-state WARNING for a different reason than "it fires an
      # unconstrained transition" — the default state of a lifecycle
      # with only constrained transitions is legitimately allowed to sit
      # forever, since nothing about *entering* it via default implies
      # anything must eventually move it, unlike a state a transition
      # explicitly delivered somewhere.
      def terminal_exempt(_lifecycle) = []

      # ── process managers / sagas ──────────────────────────────────────

      def saga_findings(bluebook, pm)
        findings = []
        emitted  = emitted_events(bluebook)
        verbs    = verbs_of(bluebook)

        [pm.starts_on, pm.ends_on].compact.each do |event|
          next if emitted.include?(bare(event))

          findings << Finding.new(kind: :deaf_trigger, severity: :error, subject: pm.name,
                                  message: "starts_on/ends_on names #{event.inspect}, which no command in this " \
                                           "domain emits")
        end

        reached = pm_reachable_states(pm, emitted)
        (Array(pm.states) - reached.to_a).each do |state|
          findings << Finding.new(kind: :unreachable_pm_state, severity: :error, subject: pm.name,
                                  message: "#{state.inspect} is declared but no handler chain from " \
                                           "#{pm.states.first.inspect} ever reaches it")
        end

        pm.handlers.each do |handler|
          # The compensating leg answers REFUSED, a synthetic trigger no
          # command ever emits by name (ProcessManager::REFUSED) — not
          # a deaf handler, the one handler this domain's own events can
          # never satisfy on purpose.
          if handler.event_type != ProcessManager::REFUSED && !emitted.include?(bare(handler.event_type))
            findings << Finding.new(kind: :deaf_handler, severity: :error, subject: pm.name,
                                    message: "a handler answers #{handler.event_type.inspect}, which no command " \
                                             "in this domain emits")
          end

          handler.dispatches.each do |dispatch|
            # SAME-DOMAIN, same as `SagaInterpreter#qualified` — a dispatch
            # naming no domain at all (the ordinary shape a bare command
            # constant now produces, S6) means THIS one, and is compared
            # against `verbs_of`'s own fully-qualified spelling qualified
            # the identical way, not left bare to miss it on a technicality.
            qualified = dispatch.command_name.include?("::") ? dispatch.command_name : "#{bluebook.name}::#{dispatch.command_name}"
            next if verbs.include?(qualified)

            findings << Finding.new(kind: :unknown_dispatch, severity: :error, subject: pm.name,
                                    message: "dispatches #{dispatch.command_name.inspect}, which this domain " \
                                             "declares no command at — cross-domain dispatch is out of this " \
                                             "checker's scope, same as CommandRules#resolve_references")
          end

          # A `compensates` DECLARED WITH NOWHERE TO EVER FIRE — the exact
          # shape of the real bug this whole feature closes ("the
          # reversal was written and never armed"), caught at build/
          # model-check time instead of discovered in production. No
          # handler anywhere answers REFUSED (`pm.saga?` false) means
          # `SagaInterpreter#unwind` never runs for this process
          # manager at all, so a declared `compensates` is structurally
          # unreachable — not a warning about style, a dead declaration.
          if !pm.saga? && handler.dispatches.any?(&:compensates)
            handler.dispatches.select(&:compensates).each do |dispatch|
              findings << Finding.new(kind: :unarmed_compensation, severity: :error, subject: pm.name,
                                      message: "#{dispatch.command_name} compensates #{dispatch.compensates.command_name}, " \
                                               "but no handler anywhere in this saga answers a refusal — the " \
                                               "compensation is declared and can never fire")
            end
          end
        end

        if pm.saga? && !reached.include?(pm.saga.from_state)
          findings << Finding.new(kind: :dead_compensation, severity: :error, subject: pm.name,
                                  message: "the compensation leaves #{pm.saga.from_state.inspect}, which no " \
                                           "handler chain ever reaches — a refusal here can never fire it")
        end

        findings
      end

      # A handler edge is only usable in the closure if it can actually
      # FIRE — REFUSED always can (it is a compensation trigger, not an
      # event), and any other handler needs its event genuinely emitted.
      # Without this, a deaf handler's declared from_state -> to_state
      # pair reads as connected even though nothing can ever traverse
      # it, which would hide exactly the states this walk exists to
      # catch (a state only "reachable" through a handler that itself
      # never fires).
      def pm_reachable_states(pm, emitted)
        return Set.new if Array(pm.states).empty?

        reached = Set.new([pm.states.first])
        loop do
          grown = false
          pm.handlers.each do |handler|
            next unless handler.event_type == ProcessManager::REFUSED || emitted.include?(bare(handler.event_type))
            next unless reached.include?(handler.from_state)
            next if reached.include?(handler.to_state)

            reached << handler.to_state
            grown = true
          end
          break unless grown
        end
        reached
      end

      # ── policies ───────────────────────────────────────────────────────

      def policy_findings(bluebook, policy, hecksagon, known_domains)
        return cross_domain_policy_findings(policy, hecksagon, known_domains) if policy.target_domain

        emitted = emitted_events(bluebook)
        findings = []

        # `policy.event_name` (Naming.unqualified) — NOT `bare`, which only
        # strips a "::" domain qualifier. An AGGREGATE-scoped policy's
        # `on_event` carries a "." aggregate qualifier instead (PolicyBuilder
        # stores whatever was typed, verbatim — see `on "Account.
        # AccountFrozen"`), and `bare` left it untouched, silently comparing
        # "Account.AccountFrozen" against a list of bare emitted names that
        # can never contain it. Latent until now : banking's one aggregate-
        # scoped same-domain policy check would have caught it, but its only
        # prior aggregate-scoped policy (ReviewOnFreeze) is also cross-domain
        # (`across "Compliance"`), which exits this method one line above
        # before the mismatch is ever reached.
        unless emitted.include?(policy.event_name)
          findings << Finding.new(kind: :deaf_policy, severity: :error, subject: policy.name,
                                  message: "on #{policy.on_event.inspect}, which no command in this domain emits")
        end

        # `trigger` is spelled "Aggregate.Command" (or "Entity.Command" one
        # level down), completed to an FQN by PolicyInterpreter#deliver as
        # "#{domain}::#{trigger_command}" — the same join `verbs_of` builds
        # independently, so the two spellings have to be compared as FQNs,
        # never as bare command names.
        unless verbs_of(bluebook).include?("#{bluebook.name}::#{policy.trigger_command}")
          findings << Finding.new(kind: :unknown_trigger, severity: :error, subject: policy.name,
                                  message: "trigger #{policy.trigger_command.inspect} resolves to no command " \
                                           "this domain declares")
        end

        findings
      end

      # ── cross-domain policies (Context Mapping) ───────────────────────
      #
      # `uses_framework "X"` already IS a Shared Kernel relationship — it
      # merges X's own bluebook into THIS registry, no boundary. A cross-
      # domain `policy ... across: "X"` already IS a Customer/Supplier
      # relationship — it dispatches into X over real cross-Lambda RPC in
      # the Rust host (`rust/host/src/lambda_client.rs`). Neither is a new
      # word; this makes the CHOICE between them checked instead of a
      # prose comment nobody enforces (`examples/banking/bluebook/
      # banking.hecksagon`'s own hand-written note explaining why
      # Compliance is reached via `across`, never `uses_framework`).
      #
      # NO NEW KEYWORD ANYWHERE — ADR 0025 principle 1 ("one idea, one
      # spelling") refuses a `relationship:`/`as:` argument that would
      # just restate, as a string, the fact the chosen keyword (
      # `uses_framework` vs `across`) already states completely. The
      # DDD vocabulary (Shared Kernel, Customer/Supplier) lives here, in
      # the finding's own name and this comment, and in prose docs — not
      # in the grammar.
      def cross_domain_policy_findings(policy, hecksagon, known_domains)
        return [] unless hecksagon # no sibling hecksagon loaded — nothing to check a relationship against.

        target = policy.target_domain
        findings = []

        if hecksagon.framework_members.include?(target)
          # SHARED KERNEL AND CUSTOMER/SUPPLIER ARE MUTUALLY EXCLUSIVE
          # CLAIMS about the SAME target — `uses_framework` means "X is
          # loaded in-process, right here"; `across` means "X is a
          # separate deployment, reached only by RPC." Declaring both is
          # either a pointless RPC to a domain already local, or a
          # `uses_framework` that isn't really doing what its name says.
          findings << Finding.new(kind: :contradictory_relationship, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} dispatches over RPC (Customer/Supplier), " \
                                           "but this hecksagon also uses_framework #{target.inspect} (Shared " \
                                           "Kernel) — #{target} is already loaded in-process here, so the two " \
                                           "relationship declarations contradict each other for the same " \
                                           "target domain")
        elsif hecksagon.subscriptions.none? { |subscribed| Naming.qualifier(subscribed) == target }
          # THIS IS WHAT FINALLY GIVES `subscribe` REAL TEETH — checked
          # here, at model-check time, still never routed at runtime
          # (nothing dispatches off a `subscribe` line; see hecksagon.md's
          # own "checked, not routed" section). ADR 0025 names `subscribe`
          # by number as failing the corpus-use bar; this is the real use.
          findings << Finding.new(kind: :unacknowledged_relationship, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} declares a Customer/Supplier " \
                                           "relationship, but nothing in this hecksagon records the " \
                                           "expectation — add subscribe \"#{target}.SomeEvent\" for what " \
                                           "you expect back from it, or uses_framework #{target.inspect} to " \
                                           "attach it in-process instead")
        end

        # TYPO DETECTION, DELIBERATELY WEAKER — `known_domains` can only
        # ever be a MONOREPO-SCOPED heuristic: a real external hecks
        # consumer's own domain (this repo's own embryonaut/lifeadelics-
        # shaped case) lives in a genuinely separate repository this
        # corpus scan can never see, so a target this check cannot find
        # is "unknown to THIS corpus," never proof of a typo. Two real,
        # legitimate reasons a target is unresolvable — genuinely
        # undefined by design (the corpus's own "Notifications," used
        # deliberately to exercise the undelivered-reaction runtime path)
        # and real-but-external (a separate repository) — both go in
        # `ALLOWED_FINDINGS`, the same judged-exception mechanism this
        # file already uses for ExternalSettlement, rather than a new
        # keyword invented to declare "this one's fine."
        if known_domains && !known_domains.include?(target)
          findings << Finding.new(kind: :unknown_target_domain, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} names a domain nowhere in the corpus " \
                                           "this check has booted — a typo, or a real domain intentionally " \
                                           "outside this corpus (undefined by design, or living in a " \
                                           "separate repository) belongs in ALLOWED_FINDINGS, named and " \
                                           "explained, not silently assumed correct")
        end

        findings
      end

      # ── shared enumeration ────────────────────────────────────────────

      # A PORT OPERATION EMITS TOO — the primary/driving port an adapter
      # outside the bluebook calls through (see hecksagon_builder.rb) is a
      # second, real source of events, alongside a command's own `emits`.
      # Ports attach to the aggregate/bluebook from the SIBLING `.hecksagon`
      # file, not this one — a caller that boots only the `.bluebook` (as
      # the fixtures under spec/fixtures/model_check/ do, having no
      # hecksagon at all) simply finds none, which is correct : nothing
      # can be deaf to an event that isn't even wired up yet.
      def emitted_events(bluebook)
        aggregate_emits = bluebook.aggregates.flat_map do |aggregate|
          aggregate.commands.map(&:emits) +
            aggregate.entities.flat_map { |entity| entity.commands.map(&:emits) } +
            aggregate.ports.flat_map { |port| port.operations.map(&:emits) }
        end
        chapter_emits = bluebook.ports.flat_map { |port| port.operations.map(&:emits) }

        (aggregate_emits + chapter_emits).flatten.uniq
      end

      # Fully-qualified, the same spelling DispatchSpec#command_name
      # carries and fuzzing/sequence_generator/catalog.rb builds
      # independently for the same reason: a saga dispatch and a fuzzer
      # step both have to name a verb the same way the door does.
      def verbs_of(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          verbs = aggregate.commands.map { |command| "#{bluebook.name}::#{aggregate.hecks_name}.#{command.hecks_name}" }
          verbs + aggregate.entities.flat_map do |entity|
            entity.commands.map { |command|
              "#{bluebook.name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}"
            }
          end
        end
      end

      def bare(event) = event.to_s.split("::").last
    end
  end
end
