module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks that a process manager's `correlates_by` lands on a scalar field of the commands
          # that emit the events it reacts to.
          module CorrelationKeys
            private

            # `correlates_by` must land on a scalar: the dotted path is walked against each
            # command that emits an event the process manager reacts to. A command lacking the
            # first segment is skipped, since correlation has fallback tiers
            # (saga_interpreter/correlation.rb).
            def validate_correlation_keys!(process_managers, aggregates)
              process_managers.each do |pm|
                next unless pm.correlates_by

                reason = correlation_key_violation(pm, aggregates)
                next unless reason

                raise ProcessManagerBuilder::InvalidProcessManager,
                      "#{pm.name} correlates_by #{pm.correlates_by.inspect}, but #{reason}"
              end
            end

            def correlation_key_violation(process_manager, aggregates)
              head, *rest = process_manager.correlates_by.to_s.split(".")
              events = reacted_events(process_manager)

              emitting_commands(events, aggregates).each do |owner, command|
                attribute = command.attributes.find { |a| a.name == head.to_sym }
                next unless attribute

                reason = list_or_scalar_violation(owner, attribute, rest)
                return reason if reason
              end

              nil
            end

            def reacted_events(process_manager)
              ([process_manager.starts_on, process_manager.ends_on] + process_manager.handlers.map(&:event_type))
                .compact
                .reject { |event| event == ProcessManager::REFUSED }
                .map { |event| event.to_s.split("::").last }
                .uniq
            end

            def emitting_commands(events, aggregates)
              aggregates.flat_map do |aggregate|
                commands = aggregate.commands + aggregate.entities.flat_map(&:commands)
                commands.select { |command| command.emits.map(&:to_s).intersect?(events) }
                        .map { |command| [aggregate, command] }
              end
            end

            def list_or_scalar_violation(owner, attribute, segments)
              return list_key_violation(attribute.name) if attribute.list?

              walk_scalar(owner, attribute.type.to_s, segments)
            end

            def list_key_violation(label)
              "#{label} is a list — a correlation key must name one instance's own field, " \
                "not a whole collection"
            end

            # Walks the remaining dotted segments through nested value objects; nil means the walk
            # bottomed out on a scalar, otherwise the string says why it cannot.
            def walk_scalar(owner, type_name, segments)
              return scalar_end_violation(type_name) if segments.empty?

              if Attribute::PRIMITIVES.include?(type_name)
                return "#{type_name} is already a scalar — #{segments.join(".")} has nothing left to reach"
              end

              shape = owner.value_object(type_name)
              return "#{type_name} is not a value object this domain declares" unless shape

              walk_member(owner, shape, type_name, segments)
            end

            # The walk's end: a scalar, or a value object that still needs a member named.
            def scalar_end_violation(type_name)
              return nil if Attribute::PRIMITIVES.include?(type_name)

              "#{type_name} is a value object, not a scalar — name one of its own fields, " \
                "e.g. #{type_name.downcase}.value"
            end

            def walk_member(owner, shape, type_name, segments)
              segment, *rest = segments
              attribute = shape.attributes.find { |a| a.name == segment.to_sym }
              return "#{type_name} has no field #{segment.inspect}" unless attribute
              return list_key_violation("#{type_name}.#{segment}") if attribute.list?

              walk_scalar(owner, attribute.type.to_s, rest)
            end
          end
        end
      end
    end
  end
end
