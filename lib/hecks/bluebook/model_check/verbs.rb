module Hecks
  module Bluebook
    module ModelCheck
      # The names a domain declares and emits: events, command verbs and port-operation verbs.
      module Verbs
        # Every bare event name this domain's commands and port operations emit,
        # answer, or refuse — an outbound `asks` port operation has no `.emits`.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to enumerate
        # @return [Array<String>] every bare event name emitted, answered, or refused
        #   across this domain, unique
        def emitted_events(bluebook)
          aggregate_emits = bluebook.aggregates.flat_map do |aggregate|
            command_emits(aggregate) + port_operation_events(aggregate.ports)
          end
          chapter_emits = port_operation_events(bluebook.ports)

          (aggregate_emits + chapter_emits).flatten.compact.uniq
        end

        # @return [Array] what each command of the aggregate and of its entities emits
        def command_emits(aggregate)
          aggregate.commands.map(&:emits) +
            aggregate.entities.flat_map { |entity| entity.commands.map(&:emits) }
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
            prefix = "#{bluebook.name}::#{aggregate.hecks_name}"
            aggregate.commands.map { |command| "#{prefix}.#{command.hecks_name}" } +
              aggregate.entities.flat_map do |entity|
                entity.commands.map { |command| "#{prefix}.#{entity.hecks_name}.#{command.hecks_name}" }
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
end
