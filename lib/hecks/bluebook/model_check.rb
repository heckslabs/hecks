require "hecks/vocabulary"
require_relative "model_check/client_profile"

module Hecks
  module Bluebook
    # Static formal checks over the assembled bluebook IR: lifecycles as state
    # machines, process managers as protocols, checked as data without booting a runtime.
    module ModelCheck
      Finding = Struct.new(:kind, :severity, :subject, :message, keyword_init: true) do
        def to_s = "#{severity.to_s.upcase.ljust(7)} #{kind.to_s.ljust(20)} #{subject}  —  #{message}"
      end

      # Findings a domain deliberately allows, enforced in both directions by
      # spec/model_check_spec.rb: an error this checker reports but isn't listed
      # here is a regression; an entry listed but never reported is stale. Pinned
      # empty — a domain's own allowance belongs on its own declaration. (ADR 0025)
      ALLOWED_FINDINGS = {}.freeze

      # The profiles `call` accepts; `nil` is the default, unprofiled run.
      PROFILES = %i[client].freeze

      module_function

      # Runs every static model check over `bluebook` and returns what it finds.
      #
      # @param bluebook [Bluebook::Chapter] the assembled chapter to check
      # @param hecksagon [Bluebook::Hecksagon, nil] this bluebook's own sibling wiring
      #   file, if the caller loaded one
      # @param known_domains [Set<String>, nil] every bluebook/hecksagon name booted
      #   anywhere in this corpus scan, checked to catch a typo'd across/attaches target
      # @param global_emitted_events [Set<String>, nil] every event emitted anywhere in
      #   the corpus, checked as a fallback so a translates reaction isn't flagged deaf
      # @param profile [Symbol, nil] :client adds ClientProfile's error findings
      # @return [Array<Finding>] every finding this bluebook triggers
      # @raise [ArgumentError] if profile is neither nil nor :client
      def call(bluebook, hecksagon: nil, known_domains: nil, global_emitted_events: nil, rust_target: false, strict: false,
               profile: nil)
        unless profile.nil? || PROFILES.include?(profile)
          raise ArgumentError, "unknown profile #{profile.inspect} (known: #{PROFILES.inspect})"
        end

        findings = []
        bluebook.aggregates.each do |aggregate|
          findings.concat(lifecycle_findings(aggregate, aggregate))
          aggregate.entities.each { |entity| findings.concat(lifecycle_findings(aggregate, entity)) }
        end
        bluebook.process_managers.each { |process_manager| findings.concat(saga_findings(bluebook, process_manager)) }
        bluebook.policies.each do |policy|
          findings.concat(policy_findings(bluebook, policy, hecksagon, known_domains, global_emitted_events))
        end
        findings.concat(rust_reserved_name_findings(domain_name: bluebook.name,
                                                    aggregate_names: bluebook.aggregates.map(&:hecks_name),
                                                    rust_target: rust_target, strict: strict))
        findings.concat(external_query_findings(bluebook, rust_target: rust_target))
        findings.concat(ClientProfile.call(bluebook, hecksagon: hecksagon)) if profile == :client
        findings
      end

      # Flags a query the hecksagon binds to a port's adapter. Only the Ruby runtime asks an
      # adapter for an answer; a Rust host would find nothing behind the query.
      #
      # @param bluebook [Bluebook::Chapter] the assembled chapter, its hecksagon's ports attached
      # @param rust_target [Boolean] whether this domain has a real Rust target; a domain without
      #   one is not checked, since nothing but the Ruby runtime serves it
      # @return [Array<Finding>] one :external_query error per bound query, none off a Rust target
      def external_query_findings(bluebook, rust_target: false)
        return [] unless rust_target

        bluebook.aggregates.flat_map do |aggregate|
          aggregate.ports.flat_map do |port|
            port.answered_queries.map do |answer|
              Finding.new(kind: :external_query, severity: :error,
                          subject: "#{aggregate.hecks_name}.#{answer.name}",
                          message: "the #{port.name} port's adapter answers this query, and only the Ruby " \
                                   "runtime asks an adapter — the Rust host cannot serve it")
            end
          end
        end
      end

      # Flags an aggregate or domain name that collides with a Rust keyword or reserved
      # Cargo key — both become bare module identifiers with no `r#` escape hatch.
      #
      # @param domain_name [String, Symbol, nil] the domain's own name, or nil to skip
      #   the domain-level check
      # @param aggregate_names [Array<String, Symbol>] every aggregate name to check
      # @param rust_target [Boolean] raises severity to error when this domain has a
      #   real Rust target
      # @param strict [Boolean] raises severity to error regardless of rust_target
      # @return [Array<Finding>] one :rust_reserved_name finding per colliding name
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

      # The domain-level half of rust_reserved_name_findings — same tables, one name.
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

      def rust_module_name(name) = name.to_s.downcase

      # Runs every lifecycle-shaped check for one declaring construct — the aggregate
      # itself, or one of its entities — if it declares a lifecycle at all.
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

      # Finds every declared state the lifecycle's own reachability walk never reaches.
      def unreachable_state_findings(lifecycle, full, reached, subject)
        (full - reached.to_a).map do |state|
          Finding.new(kind: :unreachable_state, severity: :error, subject: subject,
                      message: "#{state.inspect} is declared (in a transition's from: or target) " \
                               "but no path from #{lifecycle.default.inspect} ever reaches it")
        end
      end

      # Finds every constrained transition whose from: states are all unreached.
      def dead_transition_findings(lifecycle, reached, subject)
        lifecycle.transitions.filter_map do |command, transition|
          next unless transition.constrained?
          next if Array(transition.from).any? { |source| reached.include?(source) }

          Finding.new(kind: :dead_transition, severity: :error, subject: subject,
                      message: "#{command} from #{Array(transition.from).inspect} can never fire — " \
                               "none of those states is ever reached")
        end
      end

      # Finds every reached state with no transition ever leaving it, unless any
      # transition in this lifecycle is unconstrained.
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

      # Finds every transition named after a command the construct doesn't declare.
      def unknown_transition_commands(lifecycle, commands, subject)
        lifecycle.transitions.filter_map do |command, _transition|
          next if commands.include?(command)

          Finding.new(kind: :unknown_command, severity: :error, subject: subject,
                      message: "a transition names #{command.inspect}, which this construct declares no command for")
        end
      end

      # Every state `lifecycle` declares in any role — default, target, or from,
      # unique.
      #
      # @param lifecycle [Bluebook::Lifecycle] the lifecycle being checked
      # @return [Array<String>] every state lifecycle declares, unique
      def full_states(lifecycle)
        (
          [lifecycle.default] +
          lifecycle.transitions.map { |_, t| t.target } +
          lifecycle.transitions.flat_map { |_, t| Array(t.from) }
        ).uniq
      end

      # Least fixpoint from the default state: an unconstrained transition always
      # fires; a constrained one fires once any of its named sources is reached.
      def reachable_states(lifecycle)
        reached = Set.new([lifecycle.default])
        loop do
          grown = false
          # `transitions` is an Array of [from, transition] pairs, not a Hash, so
          # Style/HashEachMethods' each_value rewrite is a false positive here.
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

      # Exempts only the lifecycle's own default state, and only when the lifecycle
      # declares real transitions elsewhere: entering default implies nothing about
      # ever leaving it, unlike a state some transition explicitly delivered to. An
      # empty lifecycle still warns — that reads as unfinished wiring, not a deliberate rest.
      def terminal_exempt(lifecycle)
        return [] if lifecycle.transitions.empty?

        outgoing_sources = lifecycle.transitions.flat_map { |_, t| Array(t.from) }.to_set
        outgoing_sources.include?(lifecycle.default) ? [] : [lifecycle.default]
      end

      # Runs every saga-shaped check for one process manager.
      def saga_findings(bluebook, process_manager)
        emitted = emitted_events(bluebook)
        # Parsed as (domain, aggregate, command) triples via Naming.split_verb, not
        # compared as raw strings — that's what makes an entity verb's two legitimate
        # spellings compare equal (see handler_findings' unknown_dispatch check).
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

      # Finds every declared starts_on/ends_on event this domain never emits.
      def deaf_trigger_findings(process_manager, emitted)
        [process_manager.starts_on, process_manager.ends_on].compact.filter_map do |event|
          next if emitted.include?(bare(event))

          Finding.new(kind: :deaf_trigger, severity: :error, subject: process_manager.name,
                      message: "starts_on/ends_on names #{event.inspect}, which no command in this " \
                               "domain emits")
        end
      end

      # Finds every declared state no handler chain ever reaches.
      def unreachable_pm_state_findings(process_manager, reached)
        (Array(process_manager.states) - reached.to_a).map do |state|
          Finding.new(kind: :unreachable_pm_state, severity: :error, subject: process_manager.name,
                      message: "#{state.inspect} is declared but no handler chain from " \
                               "#{process_manager.states.first.inspect} ever reaches it")
        end
      end

      # One handler's own deaf_handler/unknown_dispatch/unarmed_compensation findings.
      def handler_findings(bluebook, process_manager, emitted, verbs, handler)
        findings = []

        # The compensating leg answers `REFUSED`, a synthetic trigger no command
        # ever emits by name — deliberately exempt from the deaf-handler check.
        if handler.event_type != ProcessManager::REFUSED && !emitted.include?(bare(handler.event_type))
          findings << Finding.new(kind: :deaf_handler, severity: :error, subject: process_manager.name,
                                  message: "a handler answers #{handler.event_type.inspect}, which no command " \
                                           "in this domain emits")
        end

        handler.dispatches.each do |dispatch|
          # Always qualified against this domain's own name (no saga dispatches
          # cross-domain) and compared as a parsed triple, not a string, so an
          # entity verb's two legitimate spellings compare equal.
          qualified = Naming.split_verb("#{bluebook.name}::#{dispatch.command_name}")
          next if verbs.include?(qualified)

          findings << Finding.new(kind: :unknown_dispatch, severity: :error, subject: process_manager.name,
                                  message: "dispatches #{dispatch.command_name.inspect}, which this domain " \
                                           "declares no command at — cross-domain dispatch is out of this " \
                                           "checker's scope, same as CommandRules#resolve_references")
        end

        # No handler anywhere answers `REFUSED` means SagaInterpreter#unwind never
        # runs for this process manager, so a declared compensates is structurally
        # unreachable — a dead declaration, not a style warning.
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

      # Checks whether a saga's own compensation leaves an unreachable state.
      def dead_compensation_findings(process_manager, reached)
        return [] unless process_manager.saga? && !reached.include?(process_manager.saga.from_state)

        [Finding.new(kind: :dead_compensation, severity: :error, subject: process_manager.name,
                     message: "the compensation leaves #{process_manager.saga.from_state.inspect}, which no " \
                              "handler chain ever reaches — a refusal here can never fire it")]
      end

      # Only a handler that can actually fire extends the closure — `REFUSED` always
      # can (it's a compensation trigger, not an event); any other handler needs its
      # event genuinely emitted. Otherwise a deaf handler's edge would read as
      # connected even though nothing can ever traverse it.
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

      # Runs every same-domain policy check, or defers to
      # cross_domain_policy_findings for a cross-domain policy.
      def policy_findings(bluebook, policy, hecksagon, known_domains, global_emitted_events = nil)
        return cross_domain_policy_findings(policy, hecksagon, known_domains) if policy.target_domain

        emitted = emitted_events(bluebook)
        findings = []

        # `policy.event_name`, not `bare` — an aggregate-scoped on_event carries a
        # "." qualifier bare doesn't strip. `global_emitted_events` is a fallback for
        # a translates reaction, whose whole point is reacting to a foreign event.
        unless emitted.include?(policy.event_name) || global_emitted_events&.include?(policy.event_name)
          findings << Finding.new(kind: :deaf_policy, severity: :error, subject: policy.name,
                                  message: "on #{policy.on_event.inspect}, which no command in this domain emits")
        end

        # Completed to the same FQN verbs_of builds, then compared as a parsed
        # triple — not a string — so a port-operation trigger's spelling matches
        # the same way an entity command's does (see handler_findings above).
        qualified = Naming.split_verb("#{bluebook.name}::#{policy.trigger_command}")
        unless qualified && triggerable_verbs(bluebook).include?(qualified)
          findings << Finding.new(kind: :unknown_trigger, severity: :error, subject: policy.name,
                                  message: "trigger #{policy.trigger_command.inspect} resolves to no command " \
                                           "this domain declares")
        end

        findings
      end

      # `attaches` is a Shared Kernel relationship (X merges in, no boundary);
      # `across` is Customer/Supplier (real cross-Lambda RPC). This checks the choice
      # between them instead of leaving it as an unenforced comment. (ADR 0025)
      def cross_domain_policy_findings(policy, hecksagon, known_domains)
        return expected_undelivered_findings(policy, hecksagon, known_domains) if policy.expect_undelivered
        # No sibling hecksagon loaded — nothing to check a relationship against.
        return [] unless hecksagon

        target = policy.target_domain
        findings = []

        if hecksagon.attaches?(target)
          # Shared Kernel and Customer/Supplier are mutually exclusive claims about
          # the same target — declaring both means either a pointless RPC to a
          # domain already local, or an attaches that isn't doing its job.
          findings << Finding.new(kind: :contradictory_relationship, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} dispatches over RPC (Customer/Supplier), " \
                                           "but this hecksagon also attaches #{target.inspect} (Shared " \
                                           "Kernel) — #{target} is already loaded in-process here, so the two " \
                                           "relationship declarations contradict each other for the same " \
                                           "target domain")
        elsif hecksagon.subscriptions.none? { |subscribed| Naming.qualifier(subscribed) == target }
          # Checked here at model-check time; subscribe itself is never routed at
          # runtime (see hecksagon.md's own "checked, not routed" section).
          findings << Finding.new(kind: :unacknowledged_relationship, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} declares a Customer/Supplier " \
                                           "relationship, but nothing in this hecksagon records the " \
                                           "expectation — add subscribe \"#{target}.SomeEvent\" for what " \
                                           "you expect back from it, or attaches #{target.inspect} to " \
                                           "attach it in-process instead")
        end

        # A heuristic, not proof: an external hecks consumer's own domain lives in a
        # repo this corpus scan can't see, so "unknown here" isn't necessarily a typo.
        # A domain undefined on purpose declares so via expect_undelivered instead.
        if known_domains && !known_domains.include?(target)
          findings << Finding.new(kind: :unknown_target_domain, severity: :error, subject: policy.name,
                                  message: "across #{target.inspect} names a domain nowhere in the corpus " \
                                           "this check has booted — a typo, or a target intentionally never " \
                                           "reached, which the policy itself declares with " \
                                           "across #{target.inspect}, expect_undelivered: true")
        end

        findings
      end

      # Holds an expect_undelivered declaration to its word: the two findings an
      # unreachable target would otherwise raise are suppressed (that's the point of
      # the declaration), but if the target turns out reachable after all, the stale
      # declaration itself is now the error.
      def expected_undelivered_findings(policy, hecksagon, known_domains)
        target  = policy.target_domain
        reached = []
        reached << "#{target} is a domain this corpus boots" if known_domains&.include?(target)
        if hecksagon
          reached << "this hecksagon attaches #{target.inspect}" if hecksagon.attaches?(target)
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

      # Every bare event name this domain's commands and port operations emit,
      # answer, or refuse — an outbound `asks` port operation has no `.emits`.
      #
      # @param bluebook [Bluebook::Chapter] the assembled chapter to enumerate
      # @return [Array<String>] every bare event name emitted, answered, or refused
      #   across this domain, unique
      def emitted_events(bluebook)
        aggregate_emits = bluebook.aggregates.flat_map do |aggregate|
          aggregate.commands.map(&:emits) +
            aggregate.entities.flat_map { |entity| entity.commands.map(&:emits) } +
            port_operation_events(aggregate.ports)
        end
        chapter_emits = port_operation_events(bluebook.ports)

        (aggregate_emits + chapter_emits).flatten.compact.uniq
      end

      # One port's own emitted/answered/refused event names — an inbound operation's
      # answers/refuses are always nil, compacted by the caller.
      def port_operation_events(ports)
        ports.flat_map { |port| port.operations.flat_map { |op| [*op.emits, op.answers, op.refuses] } }
      end

      # Every command's own fully-qualified verb: "Domain::Aggregate.Command" or
      # "Domain::Aggregate.Entity.Command".
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

      # Every aggregate-owned port operation's own fully-qualified verb — only an
      # aggregate's own ports are in scope; a policy trigger never names a
      # chapter-level port directly.
      def port_verbs_of(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          aggregate.ports.flat_map do |port|
            port.operations.map do |operation|
              "#{bluebook.name}::#{aggregate.hecks_name}.#{port.name}.#{operation.hecks_name}"
            end
          end
        end
      end

      # Every triggerable verb — ordinary/entity commands plus port operations —
      # parsed through Naming.split_verb so callers never compare raw spellings.
      def triggerable_verbs(bluebook)
        (verbs_of(bluebook) + port_verbs_of(bluebook)).to_set { |verb| Naming.split_verb(verb) }
      end

      # Strips a domain qualifier off an event name.
      def bare(event) = event.to_s.split("::").last
    end
  end
end
