
module Hecksagain
  module Runtime
    class SagaInterpreter
      # The trigger lives on the declaration it triggers, not on the runtime that
      # notices it — see IR::ProcessManager::REFUSED.
      REFUSED = Bluebook::IR::ProcessManager::REFUSED

      attr_reader :registry

      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      def advance(event, domain)
        bluebook = @registry.bluebook(domain)
        return unless bluebook

        bluebook.process_managers.each do |pm|
          begin_saga(pm, event)
          advance_saga(pm, event, domain)
          end_saga(pm, event)
        end
      end

      private

      # A DOTTED PATH NAMES THE SCALAR FIELD, rather than asking a value object
      # to stand in for one. `correlates_by :end_to_end` would key a saga on
      # the whole ExternalTransfer::EndToEndReference — and Ruby and Rust
      # disagree about what a non-scalar correlation key even IS (Ruby keys on
      # the object itself, Rust on its JSON text). `:"end_to_end.value"` reads
      # the one field both runtimes can render identically.
      def saga_correlation(pm, event)
        path  = pm.correlates_by.to_s.split(".")
        # A LATER EVENT MAY ALREADY HOLD THE SCALAR. `reference.value` digs a
        # value object's field out of a FRESH declaration (TransferRequested's
        # `reference` IS a TransferReference) — but a downstream event this
        # same value was smuggled through as a passthrough argument
        # (AccountDebited's `reference:`, resolved by `dispatch_args` to the
        # bare correlation string) carries it as a scalar already, with
        # nothing left to dig. `"xfer-1".respond_to?(:[])` is true — String
        # has its OWN `[]` (substring indexing) — so checking for keyed
        # lookup explicitly, rather than "responds to `[]` at all", is what
        # stops the second segment from being read as a symbol index into a
        # string that has already arrived.
        value = path.reduce(event.payload) do |held, segment|
          held.is_a?(Hash) || held.is_a?(Value) ? held[segment.to_sym] : held
        end
        return value unless value.to_s.empty?

        # A SELF-REFERENCING LEG carries the correlation forward under ITS
        # OWN reference key ("wire", "transfer") — the address
        # `hydrate`'s "acts on an existing aggregate" branch demands when the
        # aggregate's declared identity path is not what a `with:` binding
        # supplied — not under whatever the correlates_by field happens to be
        # called ("reference.value"). That key is constant across every
        # self-referencing command on the tracked aggregate regardless of
        # which field first carried the value in, and it never collides with
        # an unrelated aggregate's own event: `Account.Debit` addresses by
        # its OWN declared identity path ("number"), never by
        # `reference_key`, so nothing is found there for an event that does
        # not belong to this saga.
        own_key = Naming.reference_key(event.aggregate).to_sym
        event.payload[own_key]
      end

      def begin_saga(pm, event)
        return unless event.name == pm.starts_on

        correlation = saga_correlation(pm, event)
        if correlation.to_s.empty?
          @registry.saga_log << { process_manager: pm.name, on: event.name,
                                  born: false, reason: "no #{pm.correlates_by} in the payload" }
          return
        end
        return if @registry.saga_instances[pm.name].key?(correlation)

        @registry.saga_instances[pm.name][correlation] =
          { state: pm.states.first, memory: event.payload }
        @registry.saga_log << { process_manager: pm.name, on: event.name,
                                instance: correlation, born: true, state: pm.states.first }
      end

      def advance_saga(pm, event, domain)
        handler = pm.handler_for(event.name)
        return unless handler

        correlation = saga_correlation(pm, event)
        return if correlation.to_s.empty?

        instance = @registry.saga_instances[pm.name][correlation]
        record   = { process_manager: pm.name, on: event.name, instance: correlation }

        unless instance
          @registry.saga_log << record.merge(advanced: false, reason: "no conversation remembers #{correlation.inspect}")
          return
        end
        unless instance[:state] == handler.from_state
          @registry.saga_log << record.merge(advanced: false,
                                             reason: "in #{instance[:state].inspect}, not #{handler.from_state.inspect}")
          return
        end

        instance[:state] = handler.to_state
        @registry.saga_log << record.merge(advanced: true, from: handler.from_state, to: handler.to_state)

        handler.dispatches.each do |spec|
          deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        end
      end

      def deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        args   = dispatch_args(pm, spec, event, instance, correlation)
        record = { process_manager: pm.name, instance: correlation, dispatch: spec.command_name }

        if @door.reaction_depth_reached?
          @registry.saga_log << record.merge(delivered: false,
                                             reason: "reaction depth #{@door.max_reaction_depth} reached")
          return
        end

        begin
          @door.reenter(qualified(spec.command_name, domain), **args)
          @registry.saga_log << record.merge(delivered: true)
        rescue *DOMAIN_REFUSALS => error
          # Same rule as the policy interpreter : a refusal by the target is
          # a recorded outcome ; a defect in the runtime is not, and now
          # flies instead of being written into the saga log as though the
          # step had simply been declined.
          @registry.saga_log << record.merge(delivered: false, reason: error.message)
          unwind(pm, event, instance, correlation, domain)
        end
      end

      # A refused leg UNWINDS — the procedure runs the leg declared `on :refused`,
      # which is where the compensation lives.
      #
      # Until this existed a refusal was RECORDED and nothing else happened. The
      # wire's thousand was taken from the source, refused by the destination, and
      # sat nowhere until a human dispatched the reversal by hand ; banking's
      # settlement left a debit standing with no credit and no reversal at all.
      # Both bluebooks had written the compensating leg. Nothing armed it.
      #
      # A compensation that is itself refused does NOT unwind again, and needs no
      # flag to stop it: the state moves to the compensating leg's to_state BEFORE
      # its dispatches run, so a second refusal finds the instance no longer in
      # from_state and records that instead. The check is the guard.
      def unwind(pm, event, instance, correlation, domain)
        handler = pm.handler_for(REFUSED)
        return unless handler && instance

        record = { process_manager: pm.name, on: REFUSED, instance: correlation }
        unless instance[:state] == handler.from_state
          @registry.saga_log << record.merge(advanced: false,
                                             reason: "in #{instance[:state].inspect}, not #{handler.from_state.inspect}")
          return
        end

        instance[:state] = handler.to_state
        @registry.saga_log << record.merge(advanced: true, from: handler.from_state, to: handler.to_state)

        handler.dispatches.each do |spec|
          deliver_saga_dispatch(pm, spec, event, instance, correlation, domain)
        end
      end

      def dispatch_args(pm, spec, event, instance, correlation)
        spec.with_spec.to_h do |key, value|
          resolved = if !value.is_a?(Symbol) then value
                     elsif value == pm.correlation_head then correlation
                     elsif event.payload.key?(value) then event.payload[value]
                     else instance[:memory][value]
                     end
          # A process manager carries facts between aggregate boundaries.  It
          # must carry a value object's state, not its source aggregate's
          # runtime type: TransferMoney and Account::Money may share fields
          # without being the same domain object.
          [key.to_sym, Value.materialize(resolved)]
        end
      end

      def qualified(command_name, domain)
        command_name.include?("::") ? command_name : "#{domain}::#{command_name}"
      end

      def end_saga(pm, event)
        return unless event.name == pm.ends_on

        correlation = saga_correlation(pm, event)
        return if correlation.to_s.empty?
        return unless @registry.saga_instances[pm.name].delete(correlation)

        @registry.saga_log << { process_manager: pm.name, on: event.name,
                                instance: correlation, ended: true }
      end
    end
  end
end
