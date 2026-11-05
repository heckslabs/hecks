module Hecks
  module Bluebook
    module DSL
      class BluebookBuilder
        module Validation
          # Checks that a process manager's `correlates_by` lands on a scalar field of the commands
          # that emit the events it reacts to.
          module CorrelationKeys
            private

            # A bare name (`correlates_by Message`) naming an aggregate of this bluebook means
            # that aggregate's identity, `"Message.id"`. Any other bare name is refused here,
            # with the message the builder gives. Runs before the other correlation
            # checks, so they only ever see the dotted form.
            def resolve_bare_correlation_keys!(bluebook)
              bluebook.process_managers.each do |process_manager|
                key = process_manager.correlates_by.to_s
                next if bare_correlation_key?(key)

                resolve_bare_correlation_key!(bluebook, process_manager, key)
              end
            end

            def bare_correlation_key?(key)
              key.empty? || key.include?(".")
            end

            def resolve_bare_correlation_key!(bluebook, process_manager, key)
              aggregate = find_correlated_aggregate(bluebook, key)
              unless aggregate
                raise ProcessManagerBuilder::InvalidProcessManager,
                      bare_correlation_message(process_manager.name, key)
              end

              path = identity_path(process_manager, aggregate)
              process_manager.correlate_by!("#{aggregate.name}.#{path}")
            end

            # The refusal for a bare name that does not name an aggregate of the bluebook.
            def bare_correlation_message(name, key)
              "#{name} correlates_by #{key}, which names a whole field rather than one of its scalars " \
                "— say which one, e.g. #{key}.value (or name an aggregate of this bluebook, " \
                "which correlates by its identity)"
            end

            def find_correlated_aggregate(bluebook, key)
              bluebook.aggregates.find { |candidate| candidate.name.to_s == Naming.demodulise(key) }
            end

            # The one field an aggregate is correlated by: its identity, or `id` when it declares
            # none.
            # A value-object identity drops its trailing `.value`, so `Thing` reads as `Thing.id`.
            def identity_path(process_manager, aggregate)
              paths = aggregate.identity_paths.map(&:to_s)
              return "id" if paths.empty?
              return paths.first.delete_suffix(".value") if paths.one?

              raise ProcessManagerBuilder::InvalidProcessManager,
                    "#{process_manager.name} correlates_by #{aggregate.name}, but #{aggregate.name} has a " \
                    "composite identity — name the one field, e.g. #{aggregate.name}.#{paths.first}"
            end

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
              events = [process_manager.starts_on, process_manager.ends_on] + process_manager.handlers.map(&:event_type)
              answered = events.compact.reject { |event| event == ProcessManager::REFUSED }
              answered.map { |event| Naming.demodulise(event) }.uniq
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
