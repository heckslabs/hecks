require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../invocation"
require_relative "../../naming"

module Hecks
  module Runtime
    class Dispatcher
      # Finds what a verb names and runs it through the interpreter that owns it. Mixed into
      # {Dispatcher}, which holds the interpreters and the registry these read.
      module Routing
        # One dispatch request as the caller spelled it: the verb, its receiver and facts, and
        # the saga correlation to stamp on emitted events.
        Call = Struct.new(:verb, :to, :with, :saga_correlation, :flat, keyword_init: true)

        private

        # Sends the call to the interpreter that owns its verb.
        #
        # @return [Array] the instance, announced events, execution plan, persistence outcome, and
        #   the outbox rows (`:enqueue` for a port operation, which saves nothing)
        def route(call, domain, aggregate, aggregate_name, command_name)
          return route_aggregate(call, domain, aggregate, aggregate_name, command_name) unless command_name.include?(".")

          head, sub = command_name.split(".", 2)
          port = aggregate.port(head)
          # Ports are checked before entities, so a port wins a name an entity also declares.
          return route_port(call, domain, aggregate, port.operation(sub) || no_operation!(head, sub)) if port

          route_entity(call, domain, aggregate, command_name)
        end

        def no_operation!(port_name, operation_name)
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "port_no_operation",
                                                        port: port_name, operation: operation_name))
        end

        # No instance comes back: a port operation hydrates and saves nothing.
        def route_port(call, domain, aggregate, operation)
          [nil, run_port_operation(call, domain, aggregate, operation), nil, nil, :enqueue]
        end

        def run_port_operation(call, domain, aggregate, operation)
          invocation = Invocation.from_call(call.verb, to: call.to, with: call.with, flat: call.flat,
                                                       receiver: :port, aggregate: aggregate) { operation }
          @port_ops.call(domain, aggregate, operation, invocation)
        end

        def route_entity(call, domain, aggregate, command_name)
          resolution = nil
          invocation = Invocation.from_call(call.verb, to: call.to, with: call.with, flat: call.flat,
                                                       receiver: :entity, entity_depth: command_name.count(".")) do
            (resolution = EntityInterpreter::Resolution.of(aggregate, command_name)).command
          end
          @entities.call(domain, aggregate, resolution, invocation)
        end

        def route_aggregate(call, domain, aggregate, aggregate_name, command_name)
          command = command_of(aggregate, aggregate_name, command_name)
          invocation = Invocation.from_call(call.verb, to: call.to, with: call.with, flat: call.flat) { command }
          @commands.call(domain, aggregate, command, invocation, call.saga_correlation)
        end

        # The entity half of an in-memory run: refuses a port verb, which has no in-memory form.
        # A `dry_run?` call has no `to`/`with`, so a key named either is an ordinary fact there.
        def dry_run_entity(call, domain, aggregate, command_name)
          refuse_port_dry_run!(call, aggregate, command_name)
          resolution = nil
          invocation = Invocation.from_call(call.verb, to: call.to, with: call.with, flat: call.flat,
                                                       receiver: :entity) do
            (resolution = EntityInterpreter::Resolution.of(aggregate, command_name)).command
          end
          @entities.call(domain, aggregate, resolution, invocation, dry_run: true)
        end

        def refuse_port_dry_run!(call, aggregate, command_name)
          return unless aggregate.port(command_name.split(".", 2).first)

          raise WiringError,
                "#{call.verb} names a port operation — dry_run? has no in-memory form for one, " \
                "only for aggregate and entity commands"
        end

        def dry_run_aggregate(call, domain, aggregate, aggregate_name, command_name)
          command = command_of(aggregate, aggregate_name, command_name)
          invocation = Invocation.from_call(call.verb, to: call.to, with: call.with, flat: call.flat) { command }
          @commands.call(domain, aggregate, command, invocation, dry_run: true)
        end

        # The call for a verb whose receiver and facts arrive together in one flat Hash: Symbol keys
        # `:to`, `:with` and `:saga_correlation` are lifted out, every other key is a fact.
        def flat_call(verb, args)
          facts = args.dup
          Call.new(verb: verb, to: facts.delete(:to), with: facts.delete(:with),
                   saga_correlation: facts.delete(:saga_correlation), flat: facts)
        end

        # Runs a call through its interpreter in memory only, as `dry_run?` and `validate` do.
        def dry_run_call(call)
          domain, aggregate_name, command_name = parse(call.verb)
          aggregate = resolve_aggregate(domain, aggregate_name, call.verb)
          return dry_run_entity(call, domain, aggregate, command_name) if command_name.include?(".")

          dry_run_aggregate(call, domain, aggregate, aggregate_name, command_name)
        end

        def parse(verb)
          Naming.split_verb(verb) ||
            raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "not_fully_qualified", verb: verb))
        end

        def command_of(aggregate, aggregate_name, command_name)
          aggregate.command(command_name) ||
            raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "aggregate_no_command",
                                                          aggregate: aggregate_name, command: command_name))
        end

        def resolve_aggregate(domain, aggregate_name, verb)
          bluebook = @registry.bluebook(domain) ||
                     raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_domain", domain: domain, verb: verb))
          bluebook.aggregate(aggregate_name) ||
            raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_aggregate",
                                                          domain: domain, aggregate: aggregate_name))
        end
      end
    end
  end
end
