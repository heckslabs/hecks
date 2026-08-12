require "set"

module Hecksagain
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
      ALLOWED_FINDINGS = {
        "banking" => [
          [:unreachable_pm_state, "ExternalSettlement"]
        ]
      }.freeze

      module_function

      def call(bluebook)
        findings = []
        bluebook.aggregates.each do |aggregate|
          findings.concat(lifecycle_findings(aggregate, aggregate))
          aggregate.entities.each { |entity| findings.concat(lifecycle_findings(aggregate, entity)) }
        end
        bluebook.process_managers.each { |pm| findings.concat(saga_findings(bluebook, pm)) }
        bluebook.policies.each { |policy| findings.concat(policy_findings(bluebook, policy)) }
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
            next if verbs.include?(dispatch.command_name)

            findings << Finding.new(kind: :unknown_dispatch, severity: :error, subject: pm.name,
                                     message: "dispatches #{dispatch.command_name.inspect}, which this domain " \
                                              "declares no command at — cross-domain dispatch is out of this " \
                                              "checker's scope, same as CommandRules#resolve_references")
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

      def policy_findings(bluebook, policy)
        return [] if policy.target_domain # cross-domain: CommandRules skips it too; so does this checker.

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
            entity.commands.map { |command| "#{bluebook.name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}" }
          end
        end
      end

      def bare(event) = event.to_s.split("::").last
    end
  end
end
