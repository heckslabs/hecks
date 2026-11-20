require "json"
require_relative "../event"
require_relative "../value"

module Hecks
  module Runtime
    class KernelDispatcher
      # Turns what the kernel answered into what the in-process engine hands its callers: each
      # announced event as a `Runtime::Event` whose payload holds the aggregate's value objects,
      # the record an event names, and a refused flat dispatch as the Ruby error class the
      # in-process path raises. Included into {KernelDispatcher}.
      module Rebuilding
        private

        def rebuild(wire)
          Event.new(name: wire["name"], aggregate: wire["aggregate"], id: wire["id"], payload: payload_of(wire),
                    occurred_at: wire["occurred_at"] || @clock.call, correlation: {}).tap(&:emit!)
        end

        # The payload as the in-process engine holds it: the emitting command's arguments, each it
        # declares coerced into its value object. A field the command does not declare, and the
        # payload of an event no described command emits (a port operation's), stays as sent.
        def payload_of(wire)
          _, aggregate = declared(wire["aggregate"])
          command = aggregate && emitter(aggregate, wire["name"])
          return wire["payload"] unless command && wire["payload"].is_a?(Hash)

          coerced(aggregate, command, JSON.parse(JSON.generate(wire["payload"]), symbolize_names: true))
        end

        # @return [Bluebook::Command, nil] the aggregate's command that emits the named event
        def emitter(aggregate, event)
          aggregate.commands.find { |command| Array(command.emits).map(&:to_s).include?(event) }
        end

        def coerced(aggregate, command, payload)
          command.attributes.each_with_object(payload) do |attribute, held|
            next unless held.key?(attribute.name)

            held[attribute.name] = Value.for_attribute(aggregate, attribute, held[attribute.name], argument: true)
          end
        end

        # The record an event names, or nil when no declarations describe its aggregate.
        def stored(fqn, id)
          domain, aggregate = declared(fqn)
          domain && repository(domain, aggregate).find(id)
        end

        # @return [Array(String, Bluebook::Aggregate), nil] the domain and aggregate `fqn` names
        def declared(fqn)
          return unless @registry

          domain, name = fqn.to_s.split("::", 2)
          aggregate = @registry.bluebook(domain)&.aggregates&.find { |candidate| candidate.name.to_s == name }
          aggregate && [domain, aggregate]
        end

        # The kernel's dispatch answer names no refusal class, so the same step is asked again as
        # a dry run, which does; the store is unchanged by a refused dispatch, so it refuses alike.
        # The message stays the dispatch's own.
        def refusal_of(verb, args, answer)
          dry = @client.call({ "dry_run" => verb, "args" => args }.merge(caller_fields))
          return Refused.new(answer.fetch("error")) if dry["ok"]

          Refusals.from_dry_run(dry.merge("error" => answer.fetch("error")))
        end
      end
    end
  end
end
