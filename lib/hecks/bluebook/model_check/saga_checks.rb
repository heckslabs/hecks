module Hecks
  module Bluebook
    module ModelCheck
      # The checks over a process manager read as a protocol: triggers nothing emits, states no
      # handler chain reaches, handlers that dispatch nothing real, and compensations that can
      # never fire.
      module SagaChecks
        # Runs every saga-shaped check for one process manager.
        def saga_findings(bluebook, process_manager)
          emitted = emitted_events(bluebook)
          # Parsed as (domain, aggregate, command) triples via Naming.split_verb, not
          # compared as raw strings — that's what makes an entity verb's two legitimate
          # spellings compare equal (see handler_findings' unknown_dispatch check).
          verbs   = verbs_of(bluebook).map { |verb| Naming.split_verb(verb) }
          reached = pm_reachable_states(process_manager, emitted)

          [
            *deaf_trigger_findings(process_manager, emitted),
            *unreachable_pm_state_findings(process_manager, reached),
            *handlers_findings(bluebook, process_manager, emitted, verbs),
            *dead_compensation_findings(process_manager, reached)
          ]
        end

        # Every handler's own findings, in declaration order.
        def handlers_findings(bluebook, process_manager, emitted, verbs)
          process_manager.handlers.flat_map do |handler|
            handler_findings(bluebook, process_manager, emitted, verbs, handler)
          end
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
          [
            *deaf_handler_findings(process_manager, emitted, handler),
            *unknown_dispatch_findings(bluebook, process_manager, verbs, handler),
            *unarmed_compensation_findings(process_manager, handler)
          ]
        end

        # The compensating leg answers `REFUSED`, a synthetic trigger no command
        # ever emits by name — deliberately exempt from the deaf-handler check.
        def deaf_handler_findings(process_manager, emitted, handler)
          return [] if handler.event_type == ProcessManager::REFUSED || emitted.include?(bare(handler.event_type))

          [Finding.new(kind: :deaf_handler, severity: :error, subject: process_manager.name,
                       message: "a handler answers #{handler.event_type.inspect}, which no command " \
                                "in this domain emits")]
        end

        # Always qualified against this domain's own name (no saga dispatches
        # cross-domain) and compared as a parsed triple, not a string, so an
        # entity verb's two legitimate spellings compare equal.
        def unknown_dispatch_findings(bluebook, process_manager, verbs, handler)
          handler.dispatches.filter_map do |dispatch|
            next if verbs.include?(Naming.split_verb("#{bluebook.name}::#{dispatch.command_name}"))

            Finding.new(kind: :unknown_dispatch, severity: :error, subject: process_manager.name,
                        message: "dispatches #{dispatch.command_name.inspect}, which this domain " \
                                 "declares no command at — cross-domain dispatch is out of this " \
                                 "checker's scope, same as CommandRules#resolve_references")
          end
        end

        # No handler anywhere answers `REFUSED` means SagaInterpreter#unwind never
        # runs for this process manager, so a declared compensates is structurally
        # unreachable — a dead declaration, not a style warning.
        def unarmed_compensation_findings(process_manager, handler)
          return [] if process_manager.saga?

          handler.dispatches.select(&:compensates).map do |dispatch|
            Finding.new(kind: :unarmed_compensation, severity: :error, subject: process_manager.name,
                        message: "#{dispatch.command_name} compensates #{dispatch.compensates.command_name}, " \
                                 "but no handler anywhere in this saga answers a refusal — the " \
                                 "compensation is declared and can never fire")
          end
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
            break unless process_manager.handlers.map { |handler| reach_handler(handler, reached, emitted) }.any?
          end
          reached
        end

        # Adds the handler's target state to `reached` when the handler can fire from it.
        #
        # @return [Set, nil] truthy when the target state was newly reached
        def reach_handler(handler, reached, emitted)
          return unless handler.event_type == ProcessManager::REFUSED || emitted.include?(bare(handler.event_type))
          return unless reached.include?(handler.from_state)

          reached.add?(handler.to_state)
        end
      end
    end
  end
end
