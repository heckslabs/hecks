require "hecks/vocabulary"

module Hecks
  module Bluebook
    # Lightweight formal methods over the IR — the same family as TLA+/
    # Alloy/P: every lifecycle is a declared finite state machine and
    # every process manager a declared protocol, and both are already
    # data, not code, so they can be model-checked rather than merely
    # executed. Static analysis only — no bluebook boots twice, no
    # runtime is touched — over what meta_validator/judge.rb and the
    # builders' own `validate!` methods leave uncovered (an undeclared
    # transition target, a dispatch to nowhere, a compensation nothing
    # can ever reach).
    #
    # **The rare property this rests on**: the model is the implementation.
    # A checker over TLA+ verifies a spec a human keeps in sync with
    # code by hand ; this verifies the same IR the runtime dispatches
    # against, so there is no second copy to drift.
    module ModelCheck
      Finding = Struct.new(:kind, :severity, :subject, :message, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{kind.to_s.ljust(20)} #{subject}  —  #{message}"
      end

      # **A finding shipped, not silenced** — the coverage-gate idiom, empty
      # allowlists enforced both directions (spec/model_check_spec.rb holds
      # this exact table: an error the checker reports and this does not
      # name is a regression, an entry the checker no longer reports is
      # stale and must be deleted). bin/model_check reads this same
      # constant, so the tool and the spec can never drift apart.
      #
      # "banking"/ExternalSettlement — found on the first real run:
      # ExternalSettlement declares `ends_on "ExternalTransferSent"`, and
      # ExternalTransfer.Send genuinely emits it — the event is real, and
      # the aggregate reaches "sent" (its own, separate lifecycle) — but
      # the saga's protocol has no `on "ExternalTransferSent"` handler, so
      # its own `state "sent"` is unreachable through the chain the
      # checker walks, and the saga's own bookkeeping (saga_log, ends_on)
      # never closes it. Real domain activity is unaffected; the saga's
      # own tracking of it is not. Left named rather than redesigning a
      # corpus fixture that is not this checker's to redesign.
      # S7, ADR 0025 — the ExternalSettlement finding once allowlisted here
      # is gone, not just quieted: its "sent" state was a
      # `state "x"` line never named by any handler's own from:/to:, a
      # pure declaration-drift artifact. States are derived from the
      # transitions that name them now (ProcessManagerBuilder#derived_
      # states), so a state nothing ever transitions into or out of no
      # longer exists to be unreachable — the finding this allowlisted
      # cannot occur any more, by construction.
      #
      # "banking"/NotifyOnClosure, FlagKeyReturn — gone from here, moved
      # to banking. `across "Notifications"` names a domain that does not
      # exist anywhere in this repo, deliberately (it exercises the
      # undelivered-reaction runtime path — `spec/runtime/policy_spec.rb`,
      # "records a reaction it cannot deliver rather than swallowing it").
      # That expectation is now declared on the two policies themselves —
      # `across "Notifications", expect_undelivered: true` — and
      # `expected_undelivered_findings` below holds it in both directions:
      # the unknown-target and unacknowledged-relationship findings are
      # expected, and a declaration whose target turns out reachable is a
      # `stale_undelivered_expectation` error. A domain's own allowance
      # lives in its own source, never in a core table keyed by its name.
      #
      # Pinned empty (spec/model_check_spec.rb), the way `bin/fuzz`'s
      # `KNOWN_FUZZ_FINDINGS` is: a finding a domain means to keep belongs
      # in that domain's own declaration.
      ALLOWED_FINDINGS = {
        # QualityControl was the first domain in this corpus to trigger an
        # `asks`/`tells` port operation from a `policy`, and once carried
        # two entries here for it — both gone now, not just quieted:
        #
        # `deaf_policy` (ClearOnPass, RefuseOnFail, RecordTheIssue,
        # RecordTheRefusal) went first: `emitted_events` below now reads an
        # outbound operation's `.answers`/`.refuses` the same way it already
        # read a command's `.emits`, so `Clearance.SuitePassed`/`SuiteFailed`
        # and `Ticket.IssueFiled`/`IssueFilingRefused` enter the known-emits
        # set for real — the same fix `bin/qa_pr_check`'s own move to
        # dispatching through the CI port (rather than `Clearance::Passed`/
        # `Failed` directly) needed to make these two policies actually fire.
        #
        # `unknown_trigger` (FileWhenSubmitted, AskOnceMore) — BUG#23 — was
        # never actually a `Naming`/`PolicyBuilder` defect, confirmed by
        # tracing the real dispatch path rather than assuming what an
        # earlier comment here claimed: `Naming.command_ref`'s bare-constant
        # rewrite does leave `trigger Ticket::IssueTracker::File` (aggregate,
        # port, operation) as "Ticket::IssueTracker.File", a leftover `::`
        # past the aggregate — but `PolicyInterpreter#deliver` re-qualifies
        # every trigger with this domain's own name before dispatch
        # ("QualityControl::Ticket::IssueTracker.File"), and `Naming.
        # split_verb` already folds that reintroduced `::` into the
        # dot-joined tail correctly (fixed for `ReactionInvocation#
        # resolve_target`) — confirmed live: a real dispatch through `Ticket.Submit` fires
        # `IssueFiled`/`TicketFiled` exactly as declared. The actual gap was
        # entirely in this checker: `verbs_of` never enumerated a port
        # operation as a triggerable verb at all, and `policy_findings`
        # compared raw strings instead of `Naming.split_verb` triples the
        # way `handler_findings`'s own `unknown_dispatch` check already does
        # (BUG#6). Fixed with `port_verbs_of`/`triggerable_verbs`, scoped
        # entirely to this file — no change to `Naming` or `PolicyBuilder`
        # was needed or made.
      }.freeze

      module_function

      # `hecksagon:`/`known_domains:` — both optional, both `nil`-safe
      # (every existing caller with no sibling hecksagon, or checking one
      # domain in isolation, behaves exactly as before). `hecksagon` is
      # this bluebook's own sibling wiring file, if the caller loaded one
      # (see `emitted_events`'s own comment on why a caller that didn't
      # simply finds none, correctly). `known_domains` is the caller's
      # own corpus-wide view — every bluebook/hecksagon name it has
      # booted anywhere, across every domain it has looked at, not just
      # this one — used only to catch a typo'd `across`/`uses_framework`
      # target; see `cross_domain_policy_findings`'s own comment for why
      # this can only ever be a corpus-scoped heuristic, never a general
      # correctness guarantee.
      #
      # `rust_target:`/`strict:` — both default false, both only change the
      # severity of `rust_reserved_name` findings (see
      # `rust_reserved_name_findings`); every other finding is unaffected.
      def call(bluebook, hecksagon: nil, known_domains: nil, rust_target: false, strict: false)
        findings = []
        bluebook.aggregates.each do |aggregate|
          findings.concat(lifecycle_findings(aggregate, aggregate))
          aggregate.entities.each { |entity| findings.concat(lifecycle_findings(aggregate, entity)) }
        end
        bluebook.process_managers.each { |process_manager| findings.concat(saga_findings(bluebook, process_manager)) }
        bluebook.policies.each { |policy| findings.concat(policy_findings(bluebook, policy, hecksagon, known_domains)) }
        findings.concat(rust_reserved_name_findings(domain_name: bluebook.name,
                                                    aggregate_names: bluebook.aggregates.map(&:hecks_name),
                                                    rust_target: rust_target, strict: strict))
        findings
      end

      # ── Rust reserved names ───────────────────────────────────────────
      #
      # A name that becomes a bare Rust module identifier with no `r#`
      # escape hatch: an aggregate (`pub mod <name.downcase>;` plus its
      # `<name.downcase>.rs` file) and a domain (`pub mod <name>;` and a
      # Cargo `[features]` key). Field names are not checked — both
      # generators already raw-escape those (`rust_ident_field`).
      #
      # The words come from the `RustReservedWord`/`CargoReservedName`
      # vocabularies, the same tables `rust/project/naming.rb` and
      # hecks-codegen's generated `reserved_names.rs` read. Both Rust
      # generators refuse through this check (`Projector.
      # reserved_name_refusal`, and its hecks-codegen port in `naming.rs`).
      #
      # Severity: a domain that only ever runs in Ruby is fine with an
      # aggregate named `Match`, so this warns by default. It is an error
      # when the caller says the domain has a Rust target (`rust_target:` —
      # `bin/model_check` reads it off the domain's Cargo feature, the
      # generators always pass it) or asks for strictness (`strict:`,
      # `bin/model_check --strict`).
      #
      # The module-name transform is `downcase`, the one both generators
      # apply to an aggregate name and to an attached chapter's name.
      #
      # @param domain_name [String, nil] the chapter's own name, checked too when present
      # @param aggregate_names [Array<String>] every aggregate name declared in the chapter
      # @param rust_target [Boolean] whether the domain has a Rust codegen target
      # @param strict [Boolean] whether to treat every reserved-name hit as an error
      # @return [Array<Finding>] one `rust_reserved_name` finding per aggregate (and the
      #   domain, when checked) whose Rust module name collides with a reserved word
      def rust_reserved_name_findings(domain_name: nil, aggregate_names: [], rust_target: false, strict: false)
        severity = rust_target || strict ? :error : :warning
        keywords = Hecks::Vocabulary.fetch("RustReservedWord")

        findings = aggregate_names.filter_map do |name|
          module_name = rust_module_name(name)
          next unless keywords.include?(module_name)

          Finding.new(kind: :rust_reserved_name, severity: severity, subject: name.to_s,
                      message: "the aggregate's Rust module `#{module_name}` is a Rust keyword (RustReservedWord) — " \
                               "`pub mod #{module_name};` has no raw-identifier escape; rename the aggregate")
        end
        findings.concat(domain_reserved_name_findings(domain_name, keywords, severity)) if domain_name
        findings
      end

      # Checks a domain's own Rust module/Cargo feature name for a collision.
      #
      # @param domain_name [String] the chapter's own name
      # @param keywords [Array<String>] the Rust reserved words already fetched, reused
      #   rather than fetched a second time
      # @param severity [Symbol] `:error` or `:warning`, as `rust_reserved_name_findings` chose
      # @return [Array<Finding>] a single-element Array holding a `rust_reserved_name`
      #   finding, or `[]` when `domain_name`'s own Rust module name is clean
      def domain_reserved_name_findings(domain_name, keywords, severity)
        module_name = rust_module_name(domain_name)
        table = if keywords.include?(module_name)
                  "a Rust keyword (RustReservedWord)"
                elsif Hecks::Vocabulary.fetch("CargoReservedName").include?(module_name)
                  "a reserved Cargo.toml key (CargoReservedName)"
                end
        return [] unless table

        [Finding.new(kind: :rust_reserved_name, severity: severity, subject: domain_name.to_s,
                     message: "the domain's Rust module and Cargo feature `#{module_name}` is #{table} — " \
                              "rename the domain")]
      end

      # Derives the Rust module name a domain or aggregate name becomes.
      #
      # @param name [String, Symbol] a domain or aggregate name
      # @return [String] the Rust module name both generators derive from it
      def rust_module_name(name) = name.to_s.downcase

      # ── lifecycles (aggregate and entity — a piece may declare one too) ──

      # Every lifecycle finding for one construct's own state machine.
      #
      # @param aggregate [Bluebook::Aggregate] the root aggregate, naming the subject
      #   for a nested entity's own findings
      # @param declaring [Bluebook::Aggregate, Bluebook::Entity] the construct whose own
      #   lifecycle to check — `aggregate` itself, or one of its entities
      # @return [Array<Finding>] every `unknown_command`/`unreachable_state`/
      #   `dead_transition`/`stuck_state` finding, or `[]` when `declaring` has no lifecycle
      def lifecycle_findings(aggregate, declaring)
        lifecycle = declaring.lifecycle
        return [] unless lifecycle

        subject = declaring.equal?(aggregate) ? aggregate.hecks_name : "#{aggregate.hecks_name}::#{declaring.hecks_name}"
        commands = Array(declaring.commands).map(&:hecks_name)

        full = full_states(lifecycle)
        reached = reachable_states(lifecycle)

        findings = []
        findings.concat(unknown_transition_commands(lifecycle, commands, subject))
        findings.concat(unreachable_state_findings(lifecycle, full, reached, subject))
        findings.concat(dead_transition_findings(lifecycle, reached, subject))
        findings.concat(stuck_state_findings(lifecycle, reached, subject))
        findings
      end

      # Finds every declared state no path from the default state ever reaches.
      #
      # @param lifecycle [Bluebook::Lifecycle] the state machine to check
      # @param full [Array<String>] every declared state — `full_states(lifecycle)`
      # @param reached [Set<String>] every reachable state — `reachable_states(lifecycle)`
      # @param subject [String] the construct's own name, for the finding
      # @return [Array<Finding>] one `unreachable_state` finding per declared state no
      #   path from the default state ever reaches
      def unreachable_state_findings(lifecycle, full, reached, subject)
        (full - reached.to_a).map do |state|
          Finding.new(kind: :unreachable_state, severity: :error, subject: subject,
                      message: "#{state.inspect} is declared (in a transition's from: or target) " \
                               "but no path from #{lifecycle.default.inspect} ever reaches it")
        end
      end

      # Finds every constrained transition whose every `from:` state is unreachable.
      #
      # @param lifecycle [Bluebook::Lifecycle] the state machine to check
      # @param reached [Set<String>] every reachable state — `reachable_states(lifecycle)`
      # @param subject [String] the construct's own name, for the finding
      # @return [Array<Finding>] one `dead_transition` finding per constrained transition
      #   whose every `from:` state is unreachable
      def dead_transition_findings(lifecycle, reached, subject)
        lifecycle.transitions.filter_map do |command, transition|
          next unless transition.constrained?
          next if Array(transition.from).any? { |source| reached.include?(source) }

          Finding.new(kind: :dead_transition, severity: :error, subject: subject,
                      message: "#{command} from #{Array(transition.from).inspect} can never fire — " \
                               "none of those states is ever reached")
        end
      end

      # Finds every reachable, non-exempt state no transition ever leaves.
      #
      # @param lifecycle [Bluebook::Lifecycle] the state machine to check
      # @param reached [Set<String>] every reachable state — `reachable_states(lifecycle)`
      # @param subject [String] the construct's own name, for the finding
      # @return [Array<Finding>] one `stuck_state` finding per reachable, non-exempt state
      #   no transition ever leaves
      def stuck_state_findings(lifecycle, reached, subject)
        any_unconstrained = lifecycle.transitions.any? { |_, t| !t.constrained? }
        (reached - terminal_exempt(lifecycle)).filter_map do |state|
          next if any_unconstrained
          next if lifecycle.transitions.any? { |_, t| t.constrained? && Array(t.from).include?(state) }

          Finding.new(kind: :stuck_state, severity: :warning, subject: subject,
                      message: "#{state.inspect} is reached but no transition ever leaves it — " \
                               "fine if that is meant to be terminal")
        end
      end

      # Finds every transition naming a command this construct does not declare.
      #
      # @param lifecycle [Bluebook::Lifecycle] the state machine to check
      # @param commands [Array<String>] every command name `declaring` actually declares
      # @param subject [String] the construct's own name, for the finding
      # @return [Array<Finding>] one `unknown_command` finding per transition naming a
      #   command `declaring` does not declare
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
      #
      # @param lifecycle [Bluebook::Lifecycle] the state machine to read
      # @return [Array<String>] every state this lifecycle declares, default first, unique
      def full_states(lifecycle)
        (
          [lifecycle.default] +
          lifecycle.transitions.map { |_, t| t.target } +
          lifecycle.transitions.flat_map { |_, t| Array(t.from) }
        ).uniq
      end

      # Least fixpoint from the default state: an unconstrained
      # transition always fires, from wherever the machine is ; a
      # constrained one fires once any of its named sources is reached.
      #
      # @param lifecycle [Bluebook::Lifecycle] the state machine to walk
      # @return [Set<String>] every state reachable from the default state
      def reachable_states(lifecycle)
        reached = Set.new([lifecycle.default])
        loop do
          grown = false
          # `transitions` is an Array of [from, transition]-shaped entries
          # (Lifecycle#transitions), not a Hash — Style/HashEachMethods'
          # `each_value` rewrite assumed otherwise from the block shape
          # alone. False positive.
          # rubocop:disable-next Style/HashEachMethods
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

      # A state with no outgoing declared path at all is exempt from the
      # stuck-state warning for a different reason than "it fires an
      # unconstrained transition" — the default state of a lifecycle
      # with only constrained transitions is legitimately allowed to sit
      # forever, since nothing about *entering* it via default implies
      # anything must eventually move it, unlike a state a transition
      # explicitly delivered somewhere.
      #
      # Scoped to `default` alone, and only when the lifecycle actually
      # declares real transitions elsewhere: an empty lifecycle (no
      # transitions at all) doesn't get this exemption — that's not "a
      # machine whose entry point deliberately awaits external action,"
      # it's much more likely a lifecycle nobody finished wiring, and
      # should still warn (see spec/fixtures/model_check/lifecycle_
      # findings.bluebook's own Widget::Part, which stays warned on
      # purpose).
      def terminal_exempt(lifecycle)
        return [] if lifecycle.transitions.empty?

        outgoing_sources = lifecycle.transitions.flat_map { |_, t| Array(t.from) }.to_set
        outgoing_sources.include?(lifecycle.default) ? [] : [lifecycle.default]
      end

      # ── process managers / sagas ──────────────────────────────────────

      # Every finding for one declared process manager, across its handlers,
      # states, and compensations.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter `process_manager` belongs to
      # @param process_manager [Bluebook::ProcessManager] the process manager to check
      # @return [Array<Finding>] every `deaf_trigger`/`unreachable_pm_state`/
      #   `deaf_handler`/`unknown_dispatch`/`unarmed_compensation`/`dead_compensation`
      #   finding
      def saga_findings(bluebook, process_manager)
        emitted = emitted_events(bluebook)
        # (domain, aggregate, command) triples, not raw strings — see
        # `handler_findings`'s own comment on the dispatch side for why:
        # `Naming.split_verb` is what makes an entity verb's two legitimate
        # spellings (`Naming.command_ref`'s own `::`-then-`.` rewrite vs.
        # `verbs_of`'s own all-`.` one) compare equal.
        verbs   = verbs_of(bluebook).map { |verb| Naming.split_verb(verb) }
        reached = pm_reachable_states(process_manager, emitted)

        findings = []
        findings.concat(deaf_trigger_findings(process_manager, emitted))
        findings.concat(unreachable_pm_state_findings(process_manager, reached))
        process_manager.handlers.each do |handler|
          findings.concat(handler_findings(bluebook, process_manager, emitted, verbs, handler))
        end
        findings.concat(dead_compensation_findings(process_manager, reached))
        findings
      end

      # Finds every `starts_on`/`ends_on` naming an event nothing in the domain emits.
      #
      # @param process_manager [Bluebook::ProcessManager] the process manager to check
      # @param emitted [Array<String>] every bare event name some command in the
      #   domain emits — `emitted_events(bluebook)`
      # @return [Array<Finding>] one `deaf_trigger` finding per `starts_on`/`ends_on`
      #   naming an event nothing emits
      def deaf_trigger_findings(process_manager, emitted)
        [process_manager.starts_on, process_manager.ends_on].compact.filter_map do |event|
          next if emitted.include?(bare(event))

          Finding.new(kind: :deaf_trigger, severity: :error, subject: process_manager.name,
                      message: "starts_on/ends_on names #{event.inspect}, which no command in this " \
                               "domain emits")
        end
      end

      # Finds every declared state no handler chain ever reaches.
      #
      # @param process_manager [Bluebook::ProcessManager] the process manager to check
      # @param reached [Set<String>] every reachable state — `pm_reachable_states`
      # @return [Array<Finding>] one `unreachable_pm_state` finding per declared state
      #   no handler chain ever reaches
      def unreachable_pm_state_findings(process_manager, reached)
        (Array(process_manager.states) - reached.to_a).map do |state|
          Finding.new(kind: :unreachable_pm_state, severity: :error, subject: process_manager.name,
                      message: "#{state.inspect} is declared but no handler chain from " \
                               "#{process_manager.states.first.inspect} ever reaches it")
        end
      end

      # One handler's own findings — deaf_handler, unknown_dispatch (one
      # per dispatch), and unarmed_compensation (one per compensating
      # dispatch), pulled out of saga_findings' own handler loop; each
      # check reads only this handler plus the domain-wide emitted/verbs
      # sets saga_findings already resolved once, no state shared between
      # handlers.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter `process_manager` belongs to
      # @param process_manager [Bluebook::ProcessManager] the owning process manager,
      #   named in each finding's own subject
      # @param emitted [Array<String>] every bare event name some command in the
      #   domain emits — `emitted_events(bluebook)`
      # @param verbs [Array<Array(String, String, String), nil>] every triggerable
      #   command, as `[domain, aggregate, command]` triples
      # @param handler [Bluebook::ProcessManagerHandler] the handler to check
      # @return [Array<Finding>] every `deaf_handler`/`unknown_dispatch`/
      #   `unarmed_compensation` finding this handler raises
      def handler_findings(bluebook, process_manager, emitted, verbs, handler)
        findings = []

        # The compensating leg answers `REFUSED`, a synthetic trigger no
        # command ever emits by name (ProcessManager::REFUSED) — not
        # a deaf handler, the one handler this domain's own events can
        # never satisfy on purpose.
        if handler.event_type != ProcessManager::REFUSED && !emitted.include?(bare(handler.event_type))
          findings << Finding.new(kind: :deaf_handler, severity: :error, subject: process_manager.name,
                                  message: "a handler answers #{handler.event_type.inspect}, which no command " \
                                           "in this domain emits")
        end

        handler.dispatches.each do |dispatch|
          # **Always this domain** — same fix, same reason, as `SagaInterpreter
          # #qualified` (BUG#6). Guessing instead — reading a dispatch whose
          # own `command_name` still carried a leftover `::` after `Naming.
          # command_ref`'s own rewrite as "already qualified" and leaving it
          # alone — hits the exact same string-shape ambiguity that
          # `SagaInterpreter#qualified`'s own comment explains at length
          # (a same-domain entity command reference and a genuinely
          # cross-domain one are textually indistinguishable after that
          # rewrite). Confirmed against the entire corpus, same as that
          # fix: no saga anywhere ever dispatches genuinely cross-domain,
          # so this checker instead qualifies exactly the way the runtime
          # actually dispatches — unconditionally against `bluebook.name`
          # — rather than maintaining its own, independently-wrong copy of
          # the same guess.
          #
          # Compared as a triple, not a string — `Naming.command_ref`'s
          # own rewrite of an entity reference (`Manifest::Slot::Fill`)
          # collapses to "Manifest::Slot.Fill" (`::` between aggregate and
          # entity, `.` before the command); `verbs_of`'s own entity
          # spelling, below, joins aggregate/entity/command all with `.`
          # instead (matching `fuzzing/sequence_generator/catalog.rb`'s own
          # independent convention, its comment's own "the same spelling"
          # claim). Both are legitimate, and `Naming.split_verb` already
          # parses either to the identical (domain, aggregate, command)
          # triple (its own comment: "past the already-resolved domain
          # boundary, any leftover `::` is unambiguous... folding it into
          # the dot-joined tail") — the same reading `ReactionInvocation.
          # resolve_target` relies on at runtime. A bare string `include?`
          # would falsely flag every entity dispatch as unknown_dispatch
          # even once correctly domain-qualified, comparing two spellings
          # of the same verb as though they were different ones.
          qualified = Naming.split_verb("#{bluebook.name}::#{dispatch.command_name}")
          next if verbs.include?(qualified)

          findings << Finding.new(kind: :unknown_dispatch, severity: :error, subject: process_manager.name,
                                  message: "dispatches #{dispatch.command_name.inspect}, which this domain " \
                                           "declares no command at — cross-domain dispatch is out of this " \
                                           "checker's scope, same as CommandRules#resolve_references")
        end

        # A `compensates` declared with nowhere to ever fire — the exact
        # shape of the real bug this whole feature closes ("the
        # reversal was written and never armed"), caught at build/
        # model-check time instead of discovered in production. No
        # handler anywhere answers `REFUSED` (`process_manager.saga?` false) means
        # `SagaInterpreter#unwind` never runs for this process
        # manager at all, so a declared `compensates` is structurally
        # unreachable — not a warning about style, a dead declaration.
        if !process_manager.saga? && handler.dispatches.any?(&:compensates)
          handler.dispatches.select(&:compensates).each do |dispatch|
            findings << Finding.new(kind: :unarmed_compensation, severity: :error, subject: process_manager.name,
                                    message: "#{dispatch.command_name} compensates #{dispatch.compensates.command_name}, " \
                                             "but no handler anywhere in this saga answers a refusal — the " \
                                             "compensation is declared and can never fire")
          end
        end

        findings
      end

      # Checks whether a saga's own compensation leaves a state nothing can ever reach.
      #
      # @param process_manager [Bluebook::ProcessManager] the process manager to check
      # @param reached [Set<String>] every reachable state — `pm_reachable_states`
      # @return [Array<Finding>] a single-element Array holding a `dead_compensation`
      #   finding, or `[]` when this saga has no compensation, or its own `from_state`
      #   is reachable
      def dead_compensation_findings(process_manager, reached)
        return [] unless process_manager.saga? && !reached.include?(process_manager.saga.from_state)

        [Finding.new(kind: :dead_compensation, severity: :error, subject: process_manager.name,
                     message: "the compensation leaves #{process_manager.saga.from_state.inspect}, which no " \
                              "handler chain ever reaches — a refusal here can never fire it")]
      end

      # A handler edge is only usable in the closure if it can actually
      # fire — `REFUSED` always can (it is a compensation trigger, not an
      # event), and any other handler needs its event genuinely emitted.
      # Without this, a deaf handler's declared from_state -> to_state
      # pair reads as connected even though nothing can ever traverse
      # it, which would hide exactly the states this walk exists to
      # catch (a state only "reachable" through a handler that itself
      # never fires).
      #
      # @param process_manager [Bluebook::ProcessManager] the process manager to walk
      # @param emitted [Array<String>] every bare event name some command in the
      #   domain emits — `emitted_events(bluebook)`
      # @return [Set<String>] every state reachable from the first declared state
      def pm_reachable_states(process_manager, emitted)
        return Set.new if Array(process_manager.states).empty?

        reached = Set.new([process_manager.states.first])
        loop do
          grown = false
          process_manager.handlers.each do |handler|
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

      # Every finding for one declared policy — same-domain checks here, cross-domain
      # ones delegated to `cross_domain_policy_findings`.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter `policy` belongs to
      # @param policy [Bluebook::Policy] the policy to check
      # @param hecksagon [Bluebook::Hecksagon, nil] this bluebook's own sibling wiring
      #   file, if the caller loaded one
      # @param known_domains [Array<String>, nil] every domain name the caller has
      #   booted anywhere, or nil to skip the typo heuristic
      # @return [Array<Finding>] every `deaf_policy`/`unknown_trigger` finding (same
      #   domain), or whatever `cross_domain_policy_findings` returns (cross domain)
      def policy_findings(bluebook, policy, hecksagon, known_domains)
        return cross_domain_policy_findings(policy, hecksagon, known_domains) if policy.target_domain

        emitted = emitted_events(bluebook)
        findings = []

        # `policy.event_name` (Naming.unqualified) — not `bare`, which only
        # strips a "::" domain qualifier. An aggregate-scoped policy's
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
        # independently, so the two spellings have to be compared as FQNs.
        #
        # Compared as a triple, not a string — `handler_findings`'s own
        # `unknown_dispatch` check (BUG#6) already applies this fix for a
        # saga's dispatch; a policy's `trigger` needed the identical one. A
        # policy triggering an `asks`/`tells` port operation (`Aggregate::
        # Port::Operation`, three colon-joined segments — `Naming.command_ref`'s
        # bare-constant rewrite turns this into "Aggregate::Port.Operation",
        # a leftover `::` past the aggregate) is a real, working dispatch —
        # `PolicyInterpreter#deliver` qualifies it with this domain's own
        # name before `Naming.split_verb` ever sees it, and `split_verb`
        # already folds that leftover `::` into the dot-joined tail
        # correctly (fixed for `ReactionInvocation#resolve_target`) —
        # but this check compared raw strings against `verbs_of`,
        # which never enumerated port operations at all, so it reported
        # every port-operation trigger as unknown regardless. `triggerable_
        # verbs` now includes both, and both sides are parsed through
        # `Naming.split_verb` before comparing, the same reading
        # `resolve_target` relies on at runtime.
        qualified = Naming.split_verb("#{bluebook.name}::#{policy.trigger_command}")
        unless qualified && triggerable_verbs(bluebook).include?(qualified)
          findings << Finding.new(kind: :unknown_trigger, severity: :error, subject: policy.name,
                                  message: "trigger #{policy.trigger_command.inspect} resolves to no command " \
                                           "this domain declares")
        end

        findings
      end

      # ── cross-domain policies (Context Mapping) ───────────────────────
      #
      # `uses_framework "X"` already is a Shared Kernel relationship — it
      # merges X's own bluebook into this registry, no boundary. A cross-
      # domain `policy ... across: "X"` already is a Customer/Supplier
      # relationship — it dispatches into X over real cross-Lambda RPC in
      # the Rust host (`rust/host/src/lambda_client.rs`). Neither is a new
      # word; this makes the choice between them checked instead of a
      # prose comment nobody enforces (`examples/banking/bluebook/
      # banking.hecksagon`'s own hand-written note explaining why
      # Compliance is reached via `across`, never `uses_framework`).
      #
      # No new keyword anywhere — ADR 0025 principle 1 ("one idea, one
      # spelling") refuses a `relationship:`/`as:` argument that would
      # just restate, as a string, the fact the chosen keyword (
      # `uses_framework` vs `across`) already states completely. The
      # DDD vocabulary (Shared Kernel, Customer/Supplier) lives here, in
      # the finding's own name and this comment, and in prose docs — not
      # in the grammar.
      #
      # @param policy [Bluebook::Policy] the cross-domain policy to check
      # @param hecksagon [Bluebook::Hecksagon, nil] this bluebook's own sibling wiring
      #   file, if the caller loaded one
      # @param known_domains [Array<String>, nil] every domain name the caller has
      #   booted anywhere, or nil to skip the typo heuristic
      # @return [Array<Finding>] every `contradictory_relationship`/
      #   `unacknowledged_relationship`/`unknown_target_domain` finding, or whatever
      #   `expected_undelivered_findings` returns when `policy.expect_undelivered`
      def cross_domain_policy_findings(policy, hecksagon, known_domains)
        return expected_undelivered_findings(policy, hecksagon, known_domains) if policy.expect_undelivered
        # No sibling hecksagon loaded — nothing to check a relationship against.
        return [] unless hecksagon

        target = policy.target_domain
        findings = []

        if hecksagon.framework_members.include?(target)
          # Shared kernel and customer/supplier are mutually exclusive
          # claims about the same target — `uses_framework` means "X is
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
          # This is what finally gives `subscribe` real teeth — checked
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

        # **Typo detection, deliberately weaker** — `known_domains` can only
        # ever be a monorepo-scoped heuristic: a real external hecks
        # consumer's own domain (this repo's own embryonaut/lifeadelics-
        # shaped case) lives in a genuinely separate repository this
        # corpus scan can never see, so a target this check cannot find
        # is "unknown to THIS corpus," never proof of a typo. A target
        # undefined by design (the corpus's own "Notifications", used
        # deliberately to exercise the undelivered-reaction runtime path)
        # declares so on its own policy — `expect_undelivered: true`,
        # checked by `expected_undelivered_findings` — rather than being
        # named in a core allowlist.
        if known_domains && !known_domains.include?(target)
          findings << Finding.new(kind: :unknown_target_domain, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} names a domain nowhere in the corpus " \
                                           "this check has booted — a typo, or a target intentionally never " \
                                           "reached, which the policy itself declares with " \
                                           "across #{target.inspect}, expect_undelivered: true")
        end

        findings
      end

      # A declared undelivered target, held to its declaration. The two
      # findings an unreachable `across` target raises (unknown target,
      # unacknowledged relationship) are what the policy declared it
      # expects, so they are not raised. What is raised is the declaration
      # going stale: the target is a domain this corpus actually booted,
      # or the sibling hecksagon attaches or subscribes to it — either way
      # the reaction can be delivered, and the declaration is now a lie.
      # `known_domains` is nil for a single-target run, which can then only
      # check the hecksagon half.
      #
      # @param policy [Bluebook::Policy] the policy declaring `expect_undelivered: true`
      # @param hecksagon [Bluebook::Hecksagon, nil] this bluebook's own sibling wiring
      #   file, if the caller loaded one
      # @param known_domains [Array<String>, nil] every domain name the caller has
      #   booted anywhere, or nil to check only the hecksagon half
      # @return [Array<Finding>] a single-element Array holding a
      #   `stale_undelivered_expectation` finding, or `[]` when the target is still
      #   genuinely unreachable
      def expected_undelivered_findings(policy, hecksagon, known_domains)
        target  = policy.target_domain
        reached = []
        reached << "#{target} is a domain this corpus boots" if known_domains&.include?(target)
        if hecksagon
          reached << "this hecksagon uses_framework #{target.inspect}" if hecksagon.framework_members.include?(target)
          if hecksagon.subscriptions.any? { |subscribed| Naming.qualifier(subscribed) == target }
            reached << "this hecksagon subscribes to #{target}"
          end
        end
        return [] if reached.empty?

        [Finding.new(kind: :stale_undelivered_expectation, severity: :error, subject: policy.name,
                     message: "across #{target.inspect}, expect_undelivered: true — but #{reached.join(' and ')}, " \
                              "so the reaction can be delivered after all; drop expect_undelivered: or remove " \
                              "what reaches #{target}")]
      end

      # ── shared enumeration ────────────────────────────────────────────

      # A port operation emits too — the primary/driving port an adapter
      # outside the bluebook calls through (see hecksagon_builder.rb) is a
      # second, real source of events, alongside a command's own `emits`.
      # Ports attach to the aggregate/bluebook from the sibling `.hecksagon`
      # file, not this one — a caller that boots only the `.bluebook` (as
      # the fixtures under spec/fixtures/model_check/ do, having no
      # hecksagon at all) simply finds none, which is correct : nothing
      # can be deaf to an event that isn't even wired up yet.
      #
      # An outbound operation (`asks`) emits through a different door — it
      # declares no `.emits` at all (`PortOperationBuilder#refuse_wrong_
      # words!` refuses one that tries), naming its two real endings
      # `.answers`/`.refuses` instead (`PortOperation#initialize`). Reading
      # only `.emits` left every `asks`'s own two events invisible to this
      # method — real, live events a policy genuinely reacts to
      # (`Clearance.SuitePassed`/`SuiteFailed`, `Ticket.IssueFiled`/
      # `IssueFilingRefused`), reported as `deaf_policy` findings until this
      # read both. `.compact` because an inbound operation's `.answers`/
      # `.refuses` are always nil (there is no channel back to tell), which
      # would otherwise seed every emitted-events set with a stray nil.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter to read
      # @return [Array<String>] every event name emitted anywhere in this chapter —
      #   a command's own `emits`, plus a port operation's `emits`/`answers`/`refuses`
      #   — deduplicated
      def emitted_events(bluebook)
        aggregate_emits = bluebook.aggregates.flat_map do |aggregate|
          aggregate.commands.map(&:emits) +
            aggregate.entities.flat_map { |entity| entity.commands.map(&:emits) } +
            port_operation_events(aggregate.ports)
        end
        chapter_emits = port_operation_events(bluebook.ports)

        (aggregate_emits + chapter_emits).flatten.compact.uniq
      end

      # One operation, either of its own sources of events — an inbound
      # `tells` names its own via `.emits`; an outbound `asks` has none
      # (`PortOperationBuilder#refuse_wrong_words!` refuses one that
      # tries) and names its two real endings `.answers`/`.refuses`
      # instead. Pulled out of `emitted_events` above purely to keep that
      # method's own branching low enough to read at a glance — every
      # port, aggregate-owned or chapter-level, asks this the same way.
      #
      # @param ports [Array<Bluebook::DomainPort>] the ports to read
      # @return [Array<String, nil>] every event name each operation's own `.emits`,
      #   `.answers`, or `.refuses` names — nils included, for the caller to `.compact`
      def port_operation_events(ports)
        ports.flat_map { |port| port.operations.flat_map { |op| [*op.emits, op.answers, op.refuses] } }
      end

      # Fully-qualified, the same spelling DispatchSpec#command_name
      # carries and fuzzing/sequence_generator/catalog.rb builds
      # independently for the same reason: a saga dispatch and a fuzzer
      # step both have to name a verb the same way the door does.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter to read
      # @return [Array<String>] every command's own fully-qualified verb, such as
      #   `"Banking::Account.Freeze"` or `"Banking::Manifest.Slot.Fill"`
      def verbs_of(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          verbs = aggregate.commands.map { |command| "#{bluebook.name}::#{aggregate.hecks_name}.#{command.hecks_name}" }
          verbs + aggregate.entities.flat_map do |entity|
            entity.commands.map do |command|
              "#{bluebook.name}::#{aggregate.hecks_name}.#{entity.hecks_name}.#{command.hecks_name}"
            end
          end
        end
      end

      # An aggregate-owned port operation is a triggerable verb too —
      # `ReactionInvocation#resolve_target`'s own port-operation branch
      # resolves one by the exact same two-segment tail shape ("Aggregate::
      # Port.Operation", the aggregate then the port then the operation,
      # dot-joined past the domain) an entity command uses, checked first,
      # same order `Dispatcher#dispatch` already resolves a live verb in.
      # Only an aggregate's own ports (`aggregate.ports`) are in scope here
      # — a policy's `trigger` always names one aggregate, never a chapter-
      # level port with no owner to address through.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter to read
      # @return [Array<String>] every aggregate-owned port operation's own
      #   fully-qualified verb, such as `"QualityControl::Ticket.IssueTracker.File"`
      def port_verbs_of(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          aggregate.ports.flat_map do |port|
            port.operations.map do |operation|
              "#{bluebook.name}::#{aggregate.hecks_name}.#{port.name}.#{operation.hecks_name}"
            end
          end
        end
      end

      # Every triggerable verb, as a triple — `verbs_of` (ordinary/entity
      # commands) plus `port_verbs_of` (port operations), each parsed
      # through `Naming.split_verb` so a caller never has to compare two
      # spellings of the same verb as strings (see `policy_findings`'s own
      # `unknown_trigger` check for why that comparison has to happen this
      # way, not as `include?` on a raw string).
      def triggerable_verbs(bluebook)
        (verbs_of(bluebook) + port_verbs_of(bluebook)).to_set { |verb| Naming.split_verb(verb) }
      end

      # Strips a `"Domain::Event"` name down to its bare event name.
      #
      # @param event [String, Symbol] an event name, qualified or bare
      # @return [String] `event`'s own name, with any `"Domain::"` prefix removed
      def bare(event) = event.to_s.split("::").last
    end
  end
end
