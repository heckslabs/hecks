
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
