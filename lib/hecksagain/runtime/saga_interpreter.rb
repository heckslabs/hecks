# SagaInterpreter — step 8. The conversation that outlives any one command.
#
# Settlement parsed, reached the IR, was agreed on byte-for-byte by both
# parsers — and ran nowhere, in either runtime. The same silence the policies
# had, one construct along. These four steps are the machine :
#
#   born      starts_on fires and the payload carries correlates_by — an
#             instance is minted in the FIRST declared state, and it REMEMBERS
#             the starting payload (a saga exists because something has to
#             remember which half is done)
#   advanced  a handler's event arrives carrying the correlation — the instance
#             moves from→to FIRST, then the handler's dispatches fire (so a
#             nested event sees the new state) ; `with:` symbols read the event
#             payload first, the instance's memory second ; literals are
#             themselves
#   refused   a dispatch the domain turns away is RECORDED, delivered: false,
#             and the saga does not pretend — the instance already moved ; what
#             failed is on the log for the operator's queue (banking : InFlight,
#             "the list that must always empty")
#   ended     ends_on fires with the correlation — the instance retires
#
# An event that matches a handler but carries NO correlation value is not saga
# traffic (a manual Debit is just a debit) ; one that carries a correlation
# NOBODY remembers, or arrives in the wrong state, is recorded — a conversation
# out of order is a fact worth keeping.
#
# Like a policy, a saga's dispatch re-enters through the PUBLIC door, so a
# consequence is dispatched on exactly the terms any caller gets.
#
#   SagaInterpreter.new(registry, door: dispatcher).advance(event, "Banking")

module Hecksagain
  module Runtime
    class SagaInterpreter
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

      # The correlation value an event carries for one process manager :
      # the payload's correlates_by field when it rides there — and when the
      # field NAMES THE EMITTING AGGREGATE (correlates_by :transfer, event
      # from Transfer), the event's own id IS that value. `transfer` is the
      # reference-key spelling of a Transfer's identity everywhere else in
      # the language ; the saga reads it the same way, so TransferRequested
      # correlates without the domain smuggling its own id into a payload
      # field that repeats it.
      def saga_correlation(pm, event)
        value = event.payload[pm.correlates_by]
        return value unless value.to_s.empty?

        Naming.reference_key(event.aggregate) == pm.correlates_by.to_sym ? event.id : nil
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
        rescue StandardError => error
          @registry.saga_log << record.merge(delivered: false, reason: error.message)
        end
      end

      # A `with:` symbol reads, in order : the conversation's own name when
      # it IS the correlates_by field (TransferRequested never carries a
      # `transfer` key — the transfer's id lives under `id` — yet inside
      # this saga `:transfer` means exactly the correlation), then the
      # triggering event's payload, then the remembered opening payload.
      def dispatch_args(pm, spec, event, instance, correlation)
        spec.with_spec.to_h do |key, value|
          resolved = if !value.is_a?(Symbol) then value
                     elsif value == pm.correlates_by then correlation
                     elsif event.payload.key?(value) then event.payload[value]
                     else instance[:memory][value]
                     end
          [key.to_sym, resolved]
        end
      end

      # A saga dispatch written as "Banking::Account.Debit" is already
      # qualified ; "Account.Debit" belongs to the declaring domain.
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
